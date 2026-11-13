# CopySharedLearnContent

Step L4 of making Learn content per user. Who gets a copy, why `down` does
nothing, and the deploy gate are the owner's decisions, kept in
`docs/decisions/learn-content-per-user.md` ("Order and deploy gates", step 5,
and "What L4 does"). This note covers how the copy runs.

## What is copied

Every column but `id` and `user_id`, read from the table when the copy runs,
so a content column added before L5 is copied too and none can be left out by
a hand-kept list. `generation_version` keeps the shared row's number, so the
Learn poll sees no change for text that did not change. `created_at` and
`updated_at` keep the shared row's times: they say when the text was written,
and nothing reads them as the time a user gained the row.

The migration reads only `anonymized_at` on `users`, the column `User.active`
reads, and no trial column, so it names nothing `trial_isolation_spec` guards.

## It depends on the per-user unique indexes

The insert ends in `ON CONFLICT (user_id, concept, language) DO NOTHING` (or
`(user_id, group_key)` for a guide). Those are the unique indexes L1 added,
and PostgreSQL refuses an `ON CONFLICT` target with no matching index. So an
own row is never overwritten, and a run that finds every copy in place adds
nothing. The later migration that tightens the schema (removes the shared
rows, drops the partial indexes and makes `user_id` non-null) must run after
L5's second copy, and must keep these two indexes.

## One user at a time

`copy_to_active_users` reads the active ids once, then copies each user in a
transaction of its own: one statement per table, each user's rows only. No
lock is held across the whole copy, and the migration declares
`disable_ddl_transaction!` so each user's copy commits on its own.

Inside a wrapping transaction every user's lock would be held until the last
user was copied, and an account deletion would wait for all of them.
`copy_to_active_users` raises `ArgumentError` if a transaction is already open,
so a caller that forgot `disable_ddl_transaction!` fails at once rather than
holding those locks.

## Lock order with account deletion

Each user's transaction first takes `FOR SHARE` on that user's row and checks
`anonymized_at` again, the order `GenerateConceptReferenceJob` and
`GenerateRecognitionGuideJob` use and the lock `AccountDeletion` takes
`FOR UPDATE`. A deletion that starts first finishes before the copy reads the
user, and the copy then finds no row and writes nothing. A deletion that
starts second waits for the copy to commit and then deletes the copied rows
with the rest. The lock comes before any row it inserts, so it adds no lock
cycle. The check again also covers an account anonymized after the id list
was read. `spec/migrations/copy_shared_learn_content_account_deletion_concurrency_spec.rb`
holds the copy after its `FOR SHARE` and shows deletion waiting.

## A write-up job racing the copy

A write-up job can race the copy for the same user and concept. If the copy
inserts second, `ON CONFLICT` skips it and the job's row stays. If the job
inserts second, its write raises `RecordNotUnique` (or fails its uniqueness
validation), which both jobs rescue and log. The user keeps the copied row,
and the job's provider call is wasted. The window is the few milliseconds of
one user's copy, so this is rare.

## L5 runs it again

L5's data migration (`CatchUpSharedLearnContentCopy`) copies again for every
active account still missing a copy. The SQL lives here once, so L5 calls it
rather than repeating it:

```ruby
require_relative "20261113150000_copy_shared_learn_content"
CopySharedLearnContent.copy_to_active_users(connection)
```

L5's migration must declare `disable_ddl_transaction!`; without it the guard
above raises. Only `copy_to` and `copy_to_active_users` are public; the SQL
builders are private class methods.

It stays in the migration, not in `lib/`, because a migration should not
depend on code that may change after it ran. Kept here, the SQL is part of
migration history: L5 reuses the copy as L4 shipped it, and nothing outside
`db/migrate` can edit it. So this file must not be pruned or squashed into
the schema while L5's migration requires it. The class defines no constants,
so Rails loading this file and L5 requiring it in one run only reopens the
class.

## `down` does nothing

The reason is in the decision doc. Rolling back past this step changes
nothing the code from L2 on does, since it reads own rows first and the shared
row second. L1's `down` still refuses once any owned row exists.
