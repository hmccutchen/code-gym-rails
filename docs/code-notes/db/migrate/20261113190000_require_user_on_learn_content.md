# RequireUserOnLearnContent

The schema step after L5 of making Learn content per user
(`docs/decisions/learn-content-per-user.md`, "Order and deploy gates",
step 6). It runs L4's copy once more, then deletes the shared `concept_references` and
`recognition_guides` rows (those with no `user_id`), drops the two partial
unique indexes L1 created over them, and makes `user_id` NOT NULL on both
tables. It keeps the per-user unique indexes, which L4's copy names in its
`ON CONFLICT`.

## Its deploy gate

It waits until L5 runs on both web and worker. L5 code reads and writes
only a user's own rows, so it works the same before and after this
migration, and an L5 worker may start before or after the web pre-deploy
runs it. An L4 web or worker still reads the shared rows as a fallback, so
running this while one serves would take text off a page, or let an L4
worker skip a write-up because it saw a shared row that is now gone. It
also runs after L5's catch-up copy (`CatchUpSharedLearnContentCopy`), which
needs the shared rows to copy from; migrations run in version order, so a
database that has not had the catch-up gets it first.

## Why it copies again first

L5's catch-up (`CatchUpSharedLearnContentCopy`) reads the active account ids
once, before its loop, so an account created after that read got no copy.
That includes a trial started through `/trial/start` with an invite code,
which still works because trials are paused only by hiding the link, and a
trial cannot write its own Learn content (`User#writes_learn_content?`).
Running `CopySharedLearnContent.copy_to_active_users` again right before the
delete gives every account that exists then its copy. The copy inserts only
where the user has no row yet, so an account that already has its copy, or
has written its own rows, gains nothing. The only accounts left without a
copy are those created between L5's catch-up and this migration, which L5
code already shows no shared text.

The copy raises inside an open transaction and commits one user at a time,
so the migration declares `disable_ddl_transaction!`. The delete, the index
drops and the NOT NULL change then run together in one transaction of their
own (`.require_owner`): either the shared rows are gone and the constraints
are in place, or nothing in the schema changed. If that transaction fails,
the copies stay; running the migration again copies nothing new and retries
the schema change. An account created between the copy and the delete gets
no copy, which is the same gap L5 accepted, a few milliseconds long here.

## Locking

The schema transaction first takes `ACCESS EXCLUSIVE` on both tables, references then guides,
the order `AccountData::FATES` deletes them in. Taking both up front means
the transaction never holds a weaker lock and then waits to upgrade it, so a
write-up job or an account deletion that already holds one of the tables
can finish first and nothing waits in a cycle. Reads of the two tables wait
while it runs. The tables hold one row per user for each concept and group
they have written up, a few thousand rows at most, so the delete, the
`NOT NULL` check (a full scan) and the index drops take milliseconds.

## `down`

`down` (`.allow_shared_rows`, in a transaction) makes `user_id` nullable
again and recreates the partial indexes,
the schema L5 code ran against. It cannot bring back the deleted shared
rows, and it does not raise for that: L5 code reads no shared row, so a
rollback to L5 loses nothing a user sees. Rolling back to code older than
L5, which read the shared rows, is below the floor once this has run
(`docs/decisions/learn-content-per-user.md`, Rollback).

## The older migration specs

The specs of L1, L4 and L5 build shared rows to test what those migrations
did. Around each example they call `.allow_shared_rows` and then
`.require_owner` (`spec/support/shared_learn_rows.rb`), the schema halves
without the copy, which would raise inside L1's transactional examples.
`.require_owner` deletes the shared rows they made. Both halves skip an
index that is already dropped or already there, so calling one twice does
no harm.
