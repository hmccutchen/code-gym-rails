# Daily practice compatibility

The schema adds a nullable `daily_exercises.section_order` and an exercise-owned `exercise_additions` table. A null manifest keeps the historical slot resolver, including its handling of alternate sections already stored in a set. A manifest lists one to four unique registered keys present in the set and supplies the active section order for readers. The compatibility writer clears the manifest during regeneration because it
generates content for the historical slot resolver. The single-exercise
writers commit a manifest with the new or replacement content.

Addition rows hold the exercise, request UUID, kind, captured draft scope and date, status, claim timestamp and Rails timestamps. A unique index scopes each request UUID to its exercise. A partial unique index permits one queued or running row per exercise. Account deletion removes those rows before deleting their exercise. The foreign key and the existing owner → exercise → response lock order govern future use.

The compatibility planner writes schedule-note format 1. The reader patches
`6f763795` and `82bdbb63` add strict decoding for format-2 and language-scoped
format-3 continuations while retaining the format-1 reader. The subsequent
functional release writes format 3 for enrolled single-exercise sessions.
Schedule-note format and mastery policy versions are independent.
[Single initial exercise](single-initial-exercise.md)

## Release order

Apply the compatibility migrations and roll out these readers to both web and worker before a later release emits manifests. The worker startup schema check does not wait for individual migrations, so both the manifest reader and coverage projection check the model's loaded schema. A worker with pre-migration metadata uses legacy resolution. Once the model knows the column, projections that read active sections must include it. Restart any worker that loaded schema metadata before migration, verify that both services see the column and table, and retire older processes before the writer release. The addition job depends on the table and deletion coverage already being present.

After the schema and manifest readers, prepare a separate reader release
from PR0 (`87f57fb4`) by applying only the patches from `6f763795` and
`82bdbb63`, in that order. Verify that its diff from PR0 contains only
`app/models/practice_schedule/note.rb` and
`spec/models/practice_schedule/note_spec.rb`, run the reader specs, and
verify that the legacy generation and regeneration writers are unchanged
and still write format 1. Record the resulting release revision and artifact.

Deploy that reader artifact to both web and worker and verify both services
can decode formats 1, 2 and 3. This is decoding compatibility only: the
reader artifact retains legacy writers that cannot plan generation or
regeneration from the new continuations. Do not deploy `82bdbb63` with
its full ancestry for the reader stage: its ancestor `87a17c33` already
enables format-2 writers, which PR0's format-1 readers cannot decode.
The two patch SHAs identify reader changes, not the artifact to deploy.

Before any PR1 writer starts, stop admission of generation and regeneration
from every source, including manual requests and cron. Stop or drain all
legacy writers, including the reader-stage web and worker processes,
replicas, one-off processes and in-flight provider calls. Verify that none
can resume or commit after the new writers start. There must be no window
with both legacy and PR1 writers running.

Before admitting work again, verify the compatibility migrations have
completed, both services see the manifest column and addition table, and
processes that loaded pre-migration schema metadata have been restarted.
Verify the functional release's generation and regeneration tests against
formats 1, 2 and 3; passing reader decoding tests alone does not establish
writer compatibility. Deploy the functional release to both web and worker
and verify both run that artifact before resuming admission. This cutover
temporarily makes generation and regeneration unavailable and adds no
feature flag.

After the first new-format note is committed, fix forward or roll back only
to a compatible functional release that supports both generation and
regeneration. The reader-only artifact is never a rollback target at that
point. Do not delete or reset notes to permit a rollback. Keep manifest
readers and account deletion coverage wherever those durable records exist.

The earlier format-2 reader patch (`6f763795`) alone cannot decode format 3
and is not a safe rollback after a format-3 writer has committed records.
