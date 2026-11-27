# Daily practice compatibility

The schema adds a nullable `daily_exercises.section_order` and an exercise-owned `exercise_additions` table. A null manifest keeps the historical slot resolver, including its handling of alternate sections already stored in a set. A manifest lists one to four unique registered keys present in the set and supplies the active section order for readers.

Addition rows hold the exercise, request UUID, kind, captured draft scope and date, status, claim timestamp and Rails timestamps. A unique index scopes each request UUID to its exercise. A partial unique index permits one queued or running row per exercise. Account deletion removes those rows before deleting their exercise. The foreign key and the existing owner → exercise → response lock order govern future use.

`PracticeSchedule::Note` reads both existing format 1 and format 2. Format 2 identifies the single-slot selection policy and keeps the mastery policy and service validation. It carries no legacy turn phase or omitted-kind marker. Current generation continues to write format 1.

## Release order

Apply the compatibility migrations and roll out these readers to both web and worker before a later release emits manifests or format 2. The worker startup schema check does not wait for individual migrations, so the manifest reader and coverage projection use legacy resolution when the column is absent from the loaded schema. Restart any worker that loaded schema metadata before migration, verify that both services see the column and table, and retire older processes before the writer release. The addition job likewise depends on the table and deletion coverage already being present.

This compatibility release reads format 2 for projections and policy enrollment. Its legacy generation and replacement writers still assume format 1. The first release with compatible format-2 writers establishes the minimum rollback version for those generation paths once format-2 data exists. A rollback must keep compatible writers, manifest handling and account deletion coverage wherever that durable data exists.
