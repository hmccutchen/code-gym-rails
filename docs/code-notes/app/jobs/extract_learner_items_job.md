# app/jobs/extract_learner_items_job.rb

The full decision is `docs/decisions/learner-notes.md`.

## Two triggers, one call

A set has an early run and a fallback. The early run follows the
explanation's save, or the submit on a day with no explain question, so the
call sees the explanation when there is one. The fallback runs at the later
of local midnight and an hour after submit, for a day the engineer never
explains. Both take the same `AdvisoryLock` claim on the set, so two runs
never call at once, and the set's ledger (`LearnerExtraction`, in
`plan_notes["learner_extraction"]`) decides whether a run may call. The job
creates no note row: a set without one is read for its duck turns and
answers alone. The attempt is saved before the call leaves,
so a worker that dies mid-call has spent it, and no set is ever called a
third time.

## The response it was queued for

Each run carries `daily_response_id`. Start over and regeneration destroy the
response and leave the exercise row in place, so the set keeps its id. A run
queued for the old response would otherwise read the new set, or close its
extraction before the engineer had explained it. The run checks, before it
reads the note row, that the submitted response it was queued for
is still the set's response, and stops quietly when it is not.

## Deletion during the call

The engineer can delete the note or the explanation, press Delete all or
Start over while the call is out. The merge asks `#still_there` under the
user row lock whether the response is still the one read and which of the
note and the explanation still hold the text the call read, and writes no
item citing anything gone. Closing the set afterwards answers `:gone` when
the set itself was deleted with the account, and the run logs
`set_gone` instead of failing; the merge's own `:deleted` logs
`account_deleted`.

## Arguments name the user

`user_id:` is among the arguments so `UnfinishedJobs.discard_naming` finds a
waiting fallback when the account is deleted, and `daily_exercise_id:` lets
`.discard_waiting` find one for a set whose note was deleted on the Account
page.
