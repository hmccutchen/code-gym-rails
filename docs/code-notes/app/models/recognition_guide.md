# `RecognitionGuide`

## `User#recognition_guides`, `.indexed_for` and `.missing_for`

A user reads their own guides only, never another user's, through
`user.recognition_guides`. Every row has an owner since the schema step of
`docs/decisions/learn-content-per-user.md`. `.indexed_for` indexes the user's
rows by group key. The association has no `dependent:`:
`AccountData::FATES` is the one place that deletes a user's rows. `.missing_for` lists the group keys a user has no guide
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
A guide is never rewritten, and `.write_for` does not read before it
inserts, so a second writer loses the race by raising:
`ActiveRecord::RecordNotUnique` from the unique index, or
`ActiveRecord::RecordInvalid` when the uniqueness validation already sees
the other guide. `.write_for` does not rescue either, because only the
caller knows whether losing is fine. `GenerateRecognitionGuideJob#perform`
rescues both and logs the skip, re-raising a `RecordInvalid` whose error is
not on `group_key`. A new caller must do the same.
