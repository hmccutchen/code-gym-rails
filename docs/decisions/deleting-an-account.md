# Deleting an account

**Decision (2026-11-11, owner).** "Delete my account" removes the `users`
row and every row that belongs to that person, usage rows included. It used
to call `User#anonymize!`, which blanked the email, keys and sign-in columns
but kept the exercises, responses, reviews, follow-ups, mastery and usage
rows "anonymously for team statistics". The owner chose real deletion:

- the account and every row naming it go, `api_usages` included, so spend
  totals lose those rows;
- the invite seat the account took is given back;
- accounts already anonymized are cleaned up later by a separate one-time
  run, not by this change. Until then `anonymized_at`, `User#anonymize!`,
  `#anonymized?` and `User.active` stay in the code, uncalled by deletion,
  and a later change drops them.

## One fate per table

`AccountData::FATES` is the one list of what deletion does to each table
that refers to a user, with a one-line reason for each. `AccountDeletion`
works through it in its order, and the coverage spec reads it too, so the
two cannot disagree.

| Table | Fate | Why |
| --- | --- | --- |
| `users` | delete, last | the account itself |
| `daily_exercises`, `daily_responses`, `review_follow_ups` | delete | the person's sets, answers, reviews and follow-up questions |
| `duck_threads`, `push_subscriptions` | delete | the person's conversations and browser endpoints |
| `api_usages` | delete | the person's provider calls; spend totals lose them |
| `concept_masteries`, `featured_concepts`, `level_suggestion_events`, `daily_kind_swaps` | delete | the person's standing, weekly concept and setting history |
| `judge_solves` | delete the rows with this `user_id` or on this person's sets | judge passes on the person's own sets; synthetic rows have no user |
| `invite_codes` | keep the code, give the seat back (`redeemed_count` down by one) | the code is shared |
| `suggested_concepts.reviewed_by_id` | set to NULL | the concept stays for the team |
| `concept_references`, `recognition_guides` | delete the rows with this `user_id`; shared rows (no `user_id`) stay | the person's own Learn write-ups; the shared rows name no one (`learn-content-per-user.md`) |
| `solid_queue_jobs` | delete the person's unfinished jobs that no worker has claimed or is claiming | their arguments name the person |
| the Solid Queue execution tables | go with their job row | the foreign key cascades |
| `solid_cache_entries` | keep | entries expire through `max_age` |

## The coverage spec, the fire-door inspection

`spec/conventions/user_data_coverage_spec.rb` walks the schema and fails
when something refers to a user and the fate list has no entry for that
table and column. It finds references four ways: a foreign key pointing at
`users`; a foreign key pointing at a table it already knows belongs to a
user (that is how `review_follow_ups` is found, through
`daily_responses`); a column named `user_id`, ending in `_by_id` or
containing `email`; and a `belongs_to` whose class is `User`. It does not
skip the `solid_` tables. One example plants a table for each route inside
the example's transaction and expects all four to be reported.

The same file keeps a hand-written list of what a schema walk cannot see,
and asserts each item is on it: user ids and GlobalIDs inside job
arguments; user ids in Solid Queue concurrency keys and semaphores; failed
job error text; failed jobs left by a job that was running at deletion;
emails, IP addresses and user ids inside cache keys; ids inside JSON
columns such as `concept_masteries.practice_requests`; cookies; browser
storage; logs; backups; Resend; and the AI providers. Deletion does nothing
about logs, backups, Resend or the providers, and the Account page says so.

## Locks and foreign keys

`AccountDeletion` runs in one transaction and takes locks in this order:
the user row, then the person's exercises, then responses, then mastery
rows, each in ascending id order. It deletes children before the rows their
foreign keys point at, and the coverage spec checks that `FATES` lists every
child table before its parent.

The first version of this change claimed every other writer already used
that order. The autosave did not: it locked the exercise, then inserted the
day's first response, whose foreign key waits for a key-share lock on the
user. With deletion holding the user and waiting for the exercise, Postgres
reported a deadlock. `DailyExercise#with_response_locked` now takes the user
`FOR SHARE` before the exercise, so every caller of it follows the same
order, and `spec/requests/responses_account_deletion_concurrency_spec.rb`
runs the two on separate connections.

None of the foreign keys has `ON DELETE`, so the order matters, and so do
the locks. Every table with a `user_id` foreign key takes a key-share lock
on the user row when a row is inserted, and the deletion's `FOR UPDATE` on
that row blocks it, so no running request or job can add a row for the
person once deletion has started, and one that started first finishes
before deletion reads. `review_follow_ups` points only at
`daily_responses`, so the responses are locked too: a follow-up insert that
began first is seen and deleted, and one that comes after waits and then
finds its response gone.

`suggested_concepts.reviewed_by_id` has no foreign key, so nothing in the
database stops a deleted admin's id from being written back. An admin
request signed in before its own account was deleted could promote or
dismiss a concept afterwards and leave the id there. `SuggestedConcept#review!`
takes the reviewer's row `FOR SHARE` before it writes, the same user-first
order deletion uses. A review that started first finishes, and deletion
then clears its id; one that comes after finds no reviewer, writes nothing,
and the request is sent to the login page.

Every column the deletion finds a person's rows by is indexed, so clearing
or deleting them never scans a whole table while the user row is locked.
`reviewed_by_id` was the one without an index and gained one with this
change; `user_data_coverage_spec` fails on a fate column with none.

## Unfinished jobs and Solid Queue workers

A Solid Queue worker claims a job in one transaction
(`ReadyExecution.select_and_lock` in solid_queue 1.7.2): it selects ready
executions `FOR UPDATE SKIP LOCKED`, inserts claimed executions for them, and
deletes the ready rows. The dispatcher moves scheduled jobs the same way,
and a blocked job is released under the same kind of lock.

`UnfinishedJobs` first scans the unfinished jobs for the person's id or
GlobalIDs. Between that scan and the delete a worker can claim one of them,
and the first version deleted it anyway, removing a running job's claimed
execution with it. Now, in one transaction, it locks the ready, scheduled,
blocked and failed execution rows of the matched jobs `FOR UPDATE SKIP
LOCKED`, drops any that already have a claimed execution, and deletes only
the jobs whose rows it locked. A worker that reaches a locked row skips it,
and the job is gone when the deletion commits.

A job deletion could not lock slips past: a worker was claiming or
dispatching it at that moment. It runs like a job that was already running.
A job that takes a user id finds no user and exits; a mailer job fails to
deserialize its arguments and sends nothing. Its finished row, which still
names the person, is cleared by the hourly cleanup a day later.

## Work in flight

Each path writes nothing once the account is gone:

- A generation or regeneration job finishes its provider call, then finds
  no user when it commits. `ApplicationJob#unless_account_deleted` turns
  that `RecordNotFound` into one log line, and raises it again if the user
  still exists.
- A review finds no user under its lock and returns `:set_cleared`.
- A duck reply finds no owner and returns `:deleted`.
- A follow-up reply finds its response gone and raises `RecordNotFound`,
  which the request answers with a 404.
- A usage row for a call that finished after the deletion fails on its
  foreign key; `AiService#log_usage` already rescues and logs that.
- A job enqueued earlier looks the user up by id, finds none, and exits.
- A concept write-up (`GenerateConceptReferenceJob`) share-locks the user
  before it writes and writes nothing once the account is gone, so its row
  never fails on the foreign key and the job finishes cleanly.

A mailer job enqueued with a record that is gone fails to deserialize its
arguments. Deletion removes the unfinished ones it can match, so this
happens only when a mail is enqueued in the moment before deletion commits.
Solid Queue would keep such a job as a failed execution with no
`finished_at`, which the hourly cleanup never clears, so the user's
GlobalID would stay in its arguments and error text. `ApplicationMailer`
rescues `ActiveJob::DeserializationError`, logs one line and sends nothing,
so the job finishes and is cleared a day later like any other.

A job that was already running when deletion committed and then fails for
some other reason still stays as a failed job naming the user. The coverage
spec's hand-kept list names it ("failed jobs").

## The two leftovers

- **Finished jobs.** Solid Queue keeps finished jobs, whose arguments name
  users, until something clears them. A recurring task in
  `config/recurring.yml` runs `SolidQueue::Job.clear_finished_in_batches`
  every hour, which removes jobs finished more than
  `SolidQueue.clear_finished_jobs_after` (one day) ago.
- **Cache entries.** Rate limit keys hold emails and IP addresses, and some
  cache keys hold user ids. Solid Cache removes an entry only when it is
  older than `max_age`, which defaulted to two weeks. `config/cache.yml` sets
  it to two days, longer than the longest window that reads an entry (a
  day), and `spec/config/cache_store_spec.rb` fails on a new window it does
  not know.
