# `GenerateConceptReferenceJob`

## Whose row it writes

The job writes only the user's own row (`docs/decisions/learn-content-per-user.md`).
It skips the call when the reference the user sees, their own or the shared
one, is fully written, or when it exists and this is not a refresh. A user
who sees only the shared row and asks for a rewrite gets a new row of their
own. Its `generation_version` starts one past the shared row's, because the
Learn poll compares against the version the page showed and would otherwise
never see the rewrite land. The shared row is never written.

## Concurrency

Two things keep one concept to one provider call (`docs/decisions/learn-content-per-user.md`, L3b).

The permit (`limits_concurrency` with `on_conflict: :discard`) is keyed on
the job's priority, user, language and concept. It keeps the same request
from being queued twice: a second press, or a second click, is discarded
while the first is queued or running. A click and a bulk press have
different priorities, so they never share a permit, and a click for a
concept a press already queued gets a job of its own at click priority
(issue #777). Solid Queue reads the key with the job as `self`, which is
why the lambda can read `priority`. Another user's job writes another row,
so it has its own permit too.

The claim decides which running job calls. Before the call, the job takes
an advisory lock on user, language and concept (`AdvisoryLock.hold`,
keyed by `.claim_key`) and holds it through the write. A job that finds it
held logs a skip and returns, because the holder writes the row and its
failure note answers the same poll. The claim is keyed without the
priority, so it is the one place a click and a press meet. The job checks
whether it needs to write before taking the claim and again under it, so a
job with nothing to write never holds the claim and never makes a click
skip.

## Why an advisory lock and not a `Claimable` column

The user's own row may not exist until this job creates it, so there is no
row to hold a timestamp. A column on `users` would make every other concept
of that user wait. An advisory lock needs no schema and belongs to the
database session, so a worker that dies mid-call drops it with its
connection and nothing goes stale.

## An account deleted during the call

The provider call runs outside any lock. Before writing, the job share-locks
the user row, the lock `AccountDeletion` takes for update. If deletion
committed first, the user is gone and the job writes nothing, so the insert
never fails on the foreign key. If the write committed first, deletion waits
for it and then deletes the new row with the rest of the account. Either way
the job finishes cleanly and leaves no failed execution naming the user.

## `.queue_missing`

The one way write-ups are queued for a set's concepts: on submit, at click
priority, and when a set is generated or regenerated, at
`JobPriority::BACKGROUND`, one step below the scheduled sets, so they never
run ahead of a teammate's daily set. At `JobPriority::SCHEDULED` they would
tie with the sets, and Solid Queue breaks a tie by job id, so a write-up
enqueued in an earlier hour, or early in the hourly hand-out, would run
before a set enqueued after it. `JobPriority::BULK` would have put them in
front of every set still waiting. It queues nothing for a trial account
(`User#writes_learn_content?`). Which pairs still need a write-up is
`ConceptReference.missing_for`, the same answer Learn's prepare button uses.

## A row finished by another job during the call

The claim and the permit can be bypassed (a direct `perform_now`, or an
older worker during a deploy), so two calls for one row can still overlap.
`#rewrite` checks the row again under its lock and writes nothing when it
is already fully written. The job then logs a skip, and it leaves any
failure note alone, since this call wrote nothing.
