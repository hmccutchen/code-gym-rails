# `RecognitionGuide`

## `.seen_by`, `.visible_to` and `.missing_for`

The one answer to which guide a user sees: their own row only, never
another user's. Every row has an owner since the schema step of
`docs/decisions/learn-content-per-user.md`. `.seen_by` indexes the user's
rows by group key. `.missing_for` lists the group keys a user has no guide
of their own for, which is what Learn's prepare button queues. `.written_for?` asks
about one key without loading the row, for `GenerateRecognitionGuideJob`.

## Uniqueness

The validation on `group_key` is scoped to `user_id`, matching the unique
index on `(user_id, group_key)`. `user_id` is NOT NULL, so that index
covers every row.

## `.write_for`

Saves one provider reply as the user's own guide, keeping only `FIELDS`,
and returns `:written` or `:account_deleted`. It share-locks the user row
first, as `AccountDeletion` locks it, so a deleted account gets no guide.
A guide is never rewritten, so a second insert fails on the unique index
and `GenerateRecognitionGuideJob` logs the skip.
