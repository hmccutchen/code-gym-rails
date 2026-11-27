# Daily practice compatibility

The schema adds a nullable `daily_exercises.section_order` and an exercise-owned `exercise_additions` table. A null manifest keeps the historical slot resolver, including its handling of alternate sections already stored in a set. A manifest lists one to four unique registered keys present in the set and supplies the active section order for readers. The current regeneration writer clears the manifest in the same transaction as the replacement because it generates content for the historical slot resolver.

Addition rows hold the exercise, request UUID, kind, captured draft scope and date, status, claim timestamp and Rails timestamps. A unique index scopes each request UUID to its exercise. A partial unique index permits one queued or running row per exercise. Account deletion removes those rows before deleting their exercise. The foreign key and the existing owner → exercise → response lock order govern future use.

The current planner writes schedule-note format 1, which `PracticeSchedule::Note` reads. Define format 2 with the single-slot planner in PR 1, once its continuation fields are known. Schedule-note format and mastery policy versions are independent.

## Release order

Apply the compatibility migrations and roll out these readers to both web and worker before a later release emits manifests. The worker startup schema check does not wait for individual migrations, so both the manifest reader and coverage projection check the model's loaded schema. A worker with pre-migration metadata uses legacy resolution. Once the model knows the column, projections that read active sections must include it. Restart any worker that loaded schema metadata before migration, verify that both services see the column and table, and retire older processes before the writer release. The addition job depends on the table and deletion coverage already being present.

PR 1 must ship its finalized readers before any writer emits format 2. Verify compatible web and worker readers and retire older processes before activating the new writer. Once format-2 data exists, keep compatible writers for generation and regeneration on rollback. Keep manifest handling and account deletion coverage wherever that durable data exists.
