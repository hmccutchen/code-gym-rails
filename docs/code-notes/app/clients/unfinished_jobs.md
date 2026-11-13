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

The scan reads job arguments without locks, so a worker can claim a matched
job before the delete. `still_waiting` closes that gap. It locks the matched
jobs' rows in `WAITING_EXECUTIONS` `FOR UPDATE SKIP LOCKED`, the lock a
Solid Queue worker takes on a ready execution before it claims it
(`ReadyExecution.select_and_lock`) and the dispatcher takes on a scheduled
one. It then drops any job that already has a claimed execution, and the
delete removes only the jobs left. A row a worker holds is skipped, so the
deletion never waits on a worker and never deletes a job one is claiming.
The lock and the delete share one transaction, which nests inside
`AccountDeletion`'s.

A job with no execution row at all is left alone too; Solid Queue writes the
job and its execution in one transaction, so that only happens mid-enqueue.

Deleting a job row removes its ready, scheduled, blocked or failed
execution through the foreign keys' `ON DELETE CASCADE`.
