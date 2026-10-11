# app/jobs/regenerate_exercise_job.rb

## `#regenerate`

The superseded check runs under both locks, before anything is written. A
superseded or blocked set writes nothing, so the transaction ends without a
rollback.

## `KEPT_SET_MESSAGES`

A review still running can fail, so the `reviewing` case has its own message
rather than claiming that a review landed.

## `#keep_superseded_set`

It records no error banner and releases no claim: the dashboard's set is
intact, and the claim now belongs to someone else.
