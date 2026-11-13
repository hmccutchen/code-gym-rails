# CopySharedLearnContent

Step L4 of making Learn content per user
(`docs/decisions/learn-content-per-user.md`). For every active account
(`users.anonymized_at IS NULL`, what `User.active` means) it copies every
shared `concept_references` row and every shared `recognition_guides` row
(`user_id IS NULL`) to a row that account owns. It removes nothing: the shared
rows and the read fallback stay until L5.

## What is copied

Every column but `id` and `user_id`, read from the table when the copy runs,
so a content column added before L5 is copied too and none can be left out by
a hand-kept list. `generation_version` keeps the shared row's number, so the
Learn poll sees no change for text that did not change. `created_at` and
`updated_at` keep the shared row's times: they say when the text was written,
and nothing reads them as the time a user gained the row.

## Who gets a copy

Every account with no `anonymized_at`, trial accounts included. A trial reads
the shared rows through the fallback today, so leaving it out would take text
away from it at L5. The trial rule is that a trial writes no Learn content on
the house key; a copy calls no provider and costs nothing. The migration
reads no trial column, so it names nothing `trial_isolation_spec` guards.

An anonymized account gets nothing, as the owner decided.

## Rows a user already owns

Since L2 and L3 a user can own rows written with their key. The insert ends
in `ON CONFLICT (user_id, concept, language) DO NOTHING` (or
`(user_id, group_key)` for a guide), the per-user unique indexes L1 added, so
an own row is never overwritten, and a run that finds every copy in place
adds nothing.

## One user at a time

The copy writes users × shared rows. The vocabularies hold about 120
concepts across their languages today, so there are at most a couple of
hundred shared references (a concept tag outside the vocabulary can add a
few) and a few dozen guides. A reference with its guide, ladder and lesson is
some kilobytes of text, so each user's copy is a few hundred rows and a few
megabytes, and a team of tens of accounts adds thousands of rows in all. One statement per
table per user keeps each transaction to one user's rows, so no lock is held
across the whole copy. The migration runs with `disable_ddl_transaction!` for
the same reason: each user's copy commits on its own.

Each user's transaction first takes `FOR SHARE` on that user's row and checks
`anonymized_at` again, the order `GenerateConceptReferenceJob` and
`GenerateRecognitionGuideJob` use and the lock `AccountDeletion` takes
`FOR UPDATE`. A deletion that starts first finishes before the copy reads the
user, and the copy then finds no active row and writes nothing. A deletion
that starts second waits for the copy to commit and then deletes the copied
rows with the rest. The lock comes before any row it inserts, so it adds no
lock cycle.

A write-up job can race the copy for the same user and concept. Whichever
inserts second either skips (the copy, through `ON CONFLICT`) or raises
`RecordNotUnique`, which both jobs already rescue and log. The user keeps one
row either way.

## L5 runs it again

L5's data migration copies again for every active account still missing a
copy. The SQL lives here once, as class methods, so L5 calls it rather than
repeating it:

```ruby
require_relative "20261113150000_copy_shared_learn_content"
CopySharedLearnContent.copy_to_active_users(connection)
```

It stays in the migration, not in `lib/`, because a migration should not
depend on code that may change after it ran. Kept here, the SQL is part of
migration history: L5 reuses the copy as L4 shipped it, and nothing outside
`db/migrate` can edit it. The class defines no constants, so Rails loading
this file and L5 requiring it in one run only reopens the class.

## `down` does nothing

After the copy, a copied row cannot be told apart from one the user's key
wrote, and a user may have refreshed a copied reference since. Deleting owned
rows would delete user data, and raising would block rolling back past this
step for no gain: the code from L2 on reads own rows first and the shared row
second, so the copies change nothing it does. L1's `down` still refuses once
any owned row exists.

## Deploy gate

It ships only after L2, L3 and L3b run on both web and worker. An older
writer could still create a shared row after the copy, and that row would
reach no one until L5's second run.
