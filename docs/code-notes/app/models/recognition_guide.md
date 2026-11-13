# `RecognitionGuide`

## `.seen_by`, `.visible_to` and `.missing_for`

The one answer to which guide a user sees: their own row only. Since L5 of
`docs/decisions/learn-content-per-user.md` a shared row (no `user_id`) is
never read, and neither is another user's. `.seen_by` indexes the user's
rows by group key. `.missing_for` lists the group keys a user has no guide
of their own for, which is what Learn's prepare button queues.

## Uniqueness

The validation on `group_key` is scoped to `user_id`, matching the unique
index on `(user_id, group_key)`. Shared rows have a NULL `user_id`, which
that index does not compare, so a partial index keeps them unique until the
schema step after L5 deletes them and drops it.
