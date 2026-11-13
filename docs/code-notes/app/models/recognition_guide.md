# `RecognitionGuide`

## `.seen_by`, `.visible_to` and `.missing_for`

The one answer to which guide a user sees: their own row, else the shared
row (no `user_id`), never another user's. `.seen_by` indexes the rows by
group key with the user's own row winning. `.missing_for` lists the group
keys a user sees no guide for, which is what Learn's prepare button queues.
The shared half is a fallback until L5 of
`docs/decisions/learn-content-per-user.md` drops it.

## Uniqueness

The validation on `group_key` is scoped to `user_id`, matching the unique
index on `(user_id, group_key)`. Shared rows have a NULL `user_id`, which
that index does not compare, so a partial index keeps them unique until L5.
