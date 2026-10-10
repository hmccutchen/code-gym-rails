# app/jobs/regenerate_exercise_job.rb

## `#regenerate`

A superseded claim rolls the transaction back before the response row is read
or locked. Nothing on that path depends on the response.

## `KEPT_SET_MESSAGES`

A review still running can fail, so the `reviewing` case has its own message
rather than claiming that a review landed.

## `#keep_superseded_set`

It records no error banner and releases no claim: the dashboard's set is
intact, and the claim now belongs to someone else.
