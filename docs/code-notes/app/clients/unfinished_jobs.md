# `UnfinishedJobs`

Deletes the Solid Queue jobs that name one user and have not started:
unfinished jobs with no claimed execution. A job names the user when its
serialized arguments hold a hash whose `user_id` is the user's id, which is
how every job under `app/jobs` takes its user, or a GlobalID from the list
the caller passes, which is how a mailer job holds a user or a response.

A claimed job is running, so it is left alone: deleting its row under a
worker would break the worker's bookkeeping, and the job finds no user when
it next reads one. Finished jobs are left to the hourly cleanup task in
`config/recurring.yml`.

Deleting a job row removes its ready, scheduled, blocked or failed
execution through the foreign keys' `ON DELETE CASCADE`.
