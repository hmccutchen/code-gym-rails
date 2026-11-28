# Daily practice compatibility

The schema adds a nullable `daily_exercises.section_order` and an exercise-owned `exercise_additions` table. A null manifest keeps the historical slot resolver, including its handling of alternate sections already stored in a set. A manifest lists one to four unique registered keys present in the set and supplies the active section order for readers. The compatibility writer clears the manifest during regeneration because it
generates content for the historical slot resolver. The single-exercise
writers commit a manifest with the new or replacement content.

Addition rows hold the exercise, request UUID, kind, captured draft scope and date, status, claim timestamp and Rails timestamps. A unique index scopes each request UUID to its exercise. A partial unique index permits one queued or running row per exercise. Account deletion removes those rows before deleting their exercise. The foreign key and the existing owner → exercise → response lock order govern future use.

The compatibility planner writes schedule-note format 1. The format-3
reader checkpoint (`82bdbb63`) adds strict decoding for language-scoped
continuations while retaining the format-1 and format-2 readers. The subsequent
functional release writes format 3 for enrolled single-exercise sessions.
Schedule-note format and mastery policy versions are independent.
[Single initial exercise](single-initial-exercise.md)

## Release order

Apply the compatibility migrations and roll out these readers to both web and worker before a later release emits manifests. The worker startup schema check does not wait for individual migrations, so both the manifest reader and coverage projection check the model's loaded schema. A worker with pre-migration metadata uses legacy resolution. Once the model knows the column, projections that read active sections must include it. Restart any worker that loaded schema metadata before migration, verify that both services see the column and table, and retire older processes before the writer release. The addition job depends on the table and deletion coverage already being present.

After the schema and manifest readers, release the format-3 reader
checkpoint to web and worker. Verify that both services can decode the
new format and retire older writers before the functional writer release.
Once format-3 data exists, the functional writer release, or a compatible
descendant, is the rollback floor. It supports both generation and
regeneration against the new continuation. Keep manifest readers and
account deletion coverage wherever those durable records exist.
Rollout uses release order and adds no flag.

The earlier format-2 reader checkpoint (`6f763795`) cannot decode format 3
and is not a safe rollback after a format-3 writer has committed records.
