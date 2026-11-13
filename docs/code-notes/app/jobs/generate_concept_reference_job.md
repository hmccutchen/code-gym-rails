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

The permit is keyed on user, language and concept, with `on_conflict:
:discard`. One user's refresh modes share it because they write the same
row. Another user's job writes another row, so it has its own permit and is
never discarded by this one.

## An account deleted during the call

The provider call runs outside any lock. Before writing, the job share-locks
the user row, the lock `AccountDeletion` takes for update. If deletion
committed first, the user is gone and the job writes nothing, so the insert
never fails on the foreign key. If the write committed first, deletion waits
for it and then deletes the new row with the rest of the account. Either way
the job finishes cleanly and leaves no failed execution naming the user.

## `.queue_missing`

The one way write-ups are queued for a set's concepts: on submit, at click
priority, and when a set is generated or regenerated, at scheduled priority.
Those write-ups are enqueued after that hour's scheduled sets, and Solid
Queue breaks a priority tie by job id, so they never run ahead of a
teammate's daily set. `JobPriority::BULK` would have put them in front of
every set still waiting. It queues nothing for a trial account
(`User#writes_learn_content?`). Which pairs still need a write-up is
`ConceptReference.missing_for`, the same answer Learn's prepare button uses.

## A row finished by another job during the call

Queue concurrency control can be bypassed (an expired permit, a direct
`perform_now`), so two calls for one row can overlap. `#rewrite` checks the
row again under its lock and writes nothing when it is already fully
written. The job then logs a skip, and it leaves any failure note alone,
since this call wrote nothing.
