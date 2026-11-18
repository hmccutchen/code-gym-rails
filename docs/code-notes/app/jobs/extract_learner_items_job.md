# app/jobs/extract_learner_items_job.rb

The full decision is `docs/decisions/learner-notes.md`.

## Two triggers, one call

A set has an early run and a fallback. The early run follows the
explanation's save, or the submit on a day with no explain question, so the
call sees the explanation when there is one. The fallback runs at the later
of local midnight and an hour after submit, for a day the engineer never
explains. Both take the same `AdvisoryLock` claim on the set, so two runs
never call at once, and the note row's `extract_attempts` and `extracted_at`
decide whether a run may call. The attempt is saved before the call leaves,
so a worker that dies mid-call has spent it, and no set is ever called a
third time.

## The response it was queued for

Each run carries `daily_response_id`. Start over and regeneration destroy the
response and leave the exercise row in place, so the set keeps its id. A run
queued for the old response would otherwise read the new set, or close its
extraction before the engineer had explained it. The run checks, before it
creates or reads the note row, that the submitted response it was queued for
is still the set's response, and stops quietly when it is not.

## Arguments name the user

`user_id:` is among the arguments so `UnfinishedJobs.discard_naming` finds a
waiting fallback when the account is deleted.
