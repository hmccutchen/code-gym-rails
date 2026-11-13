# `GenerateConceptReferenceJob`

## Whose row it writes

The job writes only the user's own row (`docs/decisions/learn-content-per-user.md`).
It skips the call when the user's own reference is fully written, or when it
exists and this is not a refresh. Since L5 no shared row is read, so a user
with no row of their own gets a new one with `generation_version` 1, the
first write. A rewrite only ever asks for a row the page already showed,
which is the user's own; it adds one to that row's number, and the Learn poll
compares against the number the page showed, so it sees the rewrite land.
Every reference has an owner, so the job writes no shared row.

## Concurrency

Two things keep one concept to one provider call (`docs/decisions/learn-content-per-user.md`, L3b).

The permit (`limits_concurrency` with `on_conflict: :discard`) is keyed on
the job's priority, user, language and concept. It keeps the same request
from being queued twice: a second press, or a second click, is discarded
while the first is queued or running. A click and a bulk press have
different priorities, so they never share a permit, and a click for a
concept a press already queued gets a job of its own at click priority
(issue #777). Solid Queue reads the key with the job as `self`, which is
why the lambda can read `priority`. The rest of the key is `.claim_key`,
so the permit and the claim name a concept the same way. Another user's job writes another row,
so it has its own permit too.

The claim decides which running job calls. Before the call, the job takes
an advisory lock on user, language and concept (`AdvisoryLock.hold`,
keyed by `.claim_key`) and holds it through the write. A job that finds it
held logs a skip and returns, because the holder writes the row and its
failure note answers the same poll. The claim is keyed without the
priority, so it is the one place a click and a press meet. The job checks
whether it needs to write before taking the claim and again under it, so a
job with nothing to write never holds the claim and never makes a click
skip. The second read runs inside `ConceptReference.uncached`. A job runs
inside the Rails executor with the query cache on, and the lock query does
not clear it, so without `uncached` the second read would return the
first read's answer. A job that took the claim just after another job
wrote the row would then call the provider again.

## A rewrite another job already answered

The claim alone stops two calls at once, not one after another. A ladder
press queues a refresh for every gap. If the user then clicks one of those
concepts, the click runs first at its higher priority, and its reply can be
valid prose that still lacks a complete ladder or lesson. The press's job
would then find the row not fully written and call again, a second billed
call the shared permit used to prevent before L3b.

So a refresh carries `seen_version`: the `generation_version` of the row the
user saw when it was asked for, or 0 when they saw none. Under the claim,
after the uncached read, a job whose `seen_version` no longer matches the
row skips the call, because a write has landed since the request and that is
the attempt it asked for. A later press or click reads the new version and
still retries. The skip writes nothing, so Learn's poll, which compares the
row's version with the one the page showed, sees the write that answered it.

`.queue_rewrites` is the one place that reads the version, with one query
for all of a press's pairs; Learn's single-concept click and its ladder press
both use it. `.queue_missing` passes no version. It queues only pairs the
user sees no row for, without `refresh`, and such a job already skips once
any row exists. A job queued by older code has no `seen_version` and runs as
before, since the keyword defaults to `nil` and `nil` skips the check. The
permit key reads only the user, language, concept and priority, so the new
argument never splits a permit.

## Why an advisory lock and not a `Claimable` column

The user's own row may not exist until this job creates it, so there is no
row to hold a timestamp. A column on `users` would make every other concept
of that user wait. An advisory lock needs no schema and belongs to the
database session, so a worker that dies mid-call drops it with its
connection and nothing goes stale.

## What the job keeps and what the model does

The job keeps the provider call, the claim, the failure notes and the
logging. The save is `ConceptReference.write_for`, which returns
`:written`, `:skipped` or `:account_deleted`, and the job logs each one
(issue #790). The claim stays here because `AdvisoryLock` is in
`app/clients`, which `Archspec.rb` bars models from using. The question
"is a write still wanted?" is `ConceptReference.write_wanted?`, which the
job asks before the claim and again under it, and `.write_for` asks a
third time, under the row lock when the row exists and before its insert
when it does not. The model's code note has the lock order, the skip rules
and the creation race this job's `rescue` answers.

## An account deleted during the call

The provider call runs outside any lock. `.write_for` share-locks the user
row before it writes, the lock `AccountDeletion` takes for update. If
deletion took that lock first, the write waits for it to commit, then finds
the user gone and writes nothing, so the insert never fails on the foreign
key. If the write took it first, deletion waits for it and then deletes the
new row with the rest of the account. Either way the job finishes cleanly
and leaves no failed execution naming the user.

`generate_concept_reference_account_deletion_concurrency_spec.rb` runs the
job and the deletion on two connections. It covers three cases: the write
holds the lock first, for a new row and for a refresh's rewrite, and
deletion holds it first while a new row's write waits. The job spec covers
a deletion that commits during the provider call, before the write starts.

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

## `.queue_for_new_set`

`GenerateDailyExercisesJob` and `RegenerateExerciseJob` queue a new set's
write-ups through it, after the set is saved. An enqueue can raise there:
Solid Queue turns a database error during the insert into
`SolidQueue::Job::EnqueueError`, which is not the `ActiveJob::EnqueueError`
that `perform_later` catches, and `ConceptReference.missing_for` reads the
database first, so a lost connection can raise from that read. Before #790
either error failed the set's job although the set had landed, and a
scheduled job then skipped the reminder push.

It rescues only those failures: `SolidQueue::Job::EnqueueError`, and
connection loss, which Rails raises as `ActiveRecord::ConnectionNotEstablished`
(with `ConnectionTimeoutError`, a subclass, when the pool has no free
connection) or as `ActiveRecord::ConnectionFailed` when the connection drops
during a query. It logs them at error level and the set's job goes on. The
missing write-ups are queued again on submit, or by Learn's prepare button.
Any other database error, such as a `StatementInvalid` from a broken query
in `missing_for`, is a defect, so it is not rescued and fails the job where
it can be seen. The job spec holds both sides, and the daily job's spec
raises `SolidQueue::Job::EnqueueError` from the queue adapter itself.

## A row written by another writer during the call

A direct `perform_now`, or a permit that expired while its job was still
running, bypasses only the queue's permit. Both still run `perform`, so they
take the claim and never overlap another job's call. An older worker during
a deploy takes no claim, so its call can overlap a new job's call for the
same row, and a migration that copies rows writes without the claim too. That is why
`ConceptReference.write_for` keeps its row lock: under it, it asks the same question the job asked before the call
(`.write_wanted?`, with its `refresh` and `seen_version`) of the locked row. A plain write-up that
finds a row it did not see, a rewrite whose version the row has moved past, and any job that
finds the row fully written all write nothing. The job then logs a skip, and it leaves any
failure note alone, since this call wrote nothing.
