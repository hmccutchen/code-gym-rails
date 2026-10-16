# AddTrackChosenAtToUsers

This migration ships a release before any code reads `users.track_chosen_at`.
Railway deploys web and worker separately. The web pre-deploy runs
`db:migrate`, while the worker's pre-deploy (`SchemaWait`) waits only for a
schema to exist, not for pending migrations. If the code that reads the column
reached a worker before the web had migrated, every `User` save in a job would
hit a callback reading a missing column and raise.

The backfill uses `created_at`, because no answer time was ever recorded. The
column is therefore a flag for "a welcome decision exists", not a clock. Rows
with a null `learning_track` stay null, including accounts the nightly batch
generated for before they opened `/welcome`; those are past first run because
they have exercises.

Accounts that answer the old welcome page after this deploy get
`learning_track` and no `track_chosen_at`. The PR that starts reading the
column repeats this backfill, guarded by `track_chosen_at IS NULL`.

`RepeatTrackChosenAtBackfill` is that repeat. Its down does nothing: the rows
it marks hold a `learning_track` either way, and rolled-back code reads only
that column.
