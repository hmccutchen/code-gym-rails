---
paths:
  - "railway.toml"
  - "railway.worker.toml"
  - "Dockerfile"
  - "config/database.yml"
  - "config/queue.yml"
  - "config/recurring.yml"
  - "config/puma.rb"
  - "config/environments/**"
  - "config/initializers/active_record_encryption.rb"
  - "lib/boot/**"
  - "app/clients/schema_wait.rb"
  - "db/migrate/**"
---

# Railway deployment


- Project: `Code Gym` (ID: `5b53ac62-bdb2-4e8d-a7f2-7a457b06ba4e`)
- Web service: `web-production-246e40.up.railway.app`
- Services: web, worker, Database (Railway's Postgres 18 template, which replaced a plain `postgres:16` service after the October 2026 breach)
- Web start command: `bundle exec puma -C config/puma.rb` (set in `railway.toml`; don't use `rails server -p $PORT` — Railway start commands run in exec form, so `$PORT` is never shell-expanded, while puma reads `PORT` from ENV)
- Worker start command: `bundle exec rake solid_queue:start` (set in `railway.worker.toml`; the worker service's Settings → Config-as-code file path must point at `/railway.worker.toml`, otherwise it inherits the web config and fails healthchecks)
- Worker pre-deploy: `bundle exec rails db:wait_for_schema` (`SchemaWait`). Railway starts web and worker concurrently and orders neither, so on a PR app — where the database starts empty — a worker that wins the race dies on boot reading `solid_queue_recurring_tasks`. It waits rather than migrating: migrations keep one owner (the web pre-deploy), because `db:migrate` against an empty database performs an *unlocked schema load*, so a second migrator races and the loser dies on a duplicate constraint
- Queues and workers: a job that calls an AI provider runs on `provider_calls` (`GenerateDailyExercisesJob`, `RegenerateExerciseJob`, `GenerateConceptReferenceJob`, `GenerateRecognitionGuideJob`); everything else runs on `default` (`SendPushReminderJob`, `SweepDuckThreadsJob`, mailers, and `EnqueueDueGenerationsJob`, the hourly hand-out, which only enqueues). `JobPriority` holds the three priorities; Solid Queue takes lower numbers first within a queue, and breaks a tie by job id. A job a person waits on (a generation started from the dashboard, a single Learn write-up) runs at `JobPriority::CLICK`, the default 0, and the hand-out gives each job it starts `JobPriority::SCHEDULED`, so a click runs ahead of the scheduled sets. Learn's bulk presses (`LearnController#prepare` and `#prepare_ladders`) and the concept write-ups a saved set queues (`GenerateConceptReferenceJob.queue_missing` from `GenerateDailyExercisesJob` and `RegenerateExerciseJob`) run at `JobPriority::BACKGROUND`, below the scheduled sets, so a set enqueued after them still runs first, whether from a later hour or later in the same hand-out (`docs/decisions/learn-content-per-user.md`, L3b). A click for a concept a press already queued gets its own job: `GenerateConceptReferenceJob`'s permit key starts with the priority, and the claim the job takes when it runs (`AdvisoryLock`) keeps the two to one provider call. That claim is a PostgreSQL session advisory lock, so the app needs a direct database connection: a pooler in transaction mode (PgBouncer) could split its lock and unlock across server sessions (`docs/code-notes/app/clients/advisory_lock.md`). `config/queue.yml` gives each queue a worker entry of its own, 3 threads for `provider_calls` and 2 for `default`, and each entry is a separate process, so a login email or a push reminder never waits behind minutes-long generations. No worker lists `"*"` or both queues, since either would let provider jobs take the general threads again. A new job names one of the two queues, and `spec/conventions/job_queues_spec.rb` fails on a provider job off `provider_calls`, a queue no worker serves, or a worker that takes both
- Database pool: `config/database.yml` takes its size from `DatabasePool.size` (`lib/boot/database_pool.rb`), the larger of `RAILS_MAX_THREADS` (default 5) and what one Solid Queue worker process can need while judging: a connection per thread of the largest worker entry in `config/queue.yml` (the provider worker's 3), one more per section for each of those threads' judge fan-out (`DatabasePool::SECTIONS_PER_DAY`, restated because `database.yml` is read before `app/` loads, and held equal to `ExerciseSection::MAX_SECTIONS` by a spec), and two for Solid Queue's polling and heartbeat — 17 today. Nothing needs setting on Railway, and `spec/lib/database_pool_spec.rb` fails if the pool falls below that sum. Connections open only when a thread asks for one, so the web service, which reads the same file, opens none of the extra ceiling unless it uses them. The sizing is so the fan-out never waits for a connection: each judge and retry thread checks one out only to write its `ApiUsage` row, and a pool too small for them would make that write wait out the checkout timeout. `GenerateConceptReferenceJob` holds its thread's one connection through its provider call, for its advisory lock, which the per-thread count already covers
- Retention the privacy page states: server logs are kept 7 days on the current plan (`PrivacyNotice::LOG_DAYS`), so changing that Railway setting means changing the constant in the same change. The page states no backups, since Railway database backups are off; turning them on means adding a line to the page about how long they keep a copy in the same change
- Env vars already set in Railway: `RAILS_ENV`, `RAILS_MASTER_KEY`, all three `ACTIVE_RECORD_ENCRYPTION_*` keys, `DATABASE_URL` (points at the `Database` service)

## Migrations

- Protected practice has its own P-S/P-C/P-A gates. P-S #741 supplies the
  request column. P-C implements compatible writers with initiation false;
  no new migration. Before P-A, verify web/worker SUCCESS at P-C or compatible
  descendants and stop every older writer. After v2 data exists, P-C is the
  rollback floor even after compaction. Never delete state to disable it.
  Keep #712/#714/#716 open through activation. See
  `docs/decisions/protected-practice-opportunities.md`.

- Mastery reconciliation ships S (columns), C (complete compatible writers,
  initiation false), then separately gated A (initiation true). Before A,
  positively verify web and worker SUCCESS at C or descendants and remove
  every pre-C writer, including replicas/one-offs. Existing receipts/suffixes
  always select reconciliation under the user lock, even with initiation off.
  Rollback A → C is supported; rollback earlier or deleting receipts is not.
  Keep #726 open through verified A deployment. The exact gates and costs
  are in `docs/decisions/daily-mastery-reconciliation.md`.

- The worker's pre-deploy waits for a schema, not for pending migrations, so
  a new column ships a release before any code reads it, and a column being
  removed is ignored by the model for one release before a migration drops
  it (`docs/decisions/tracks.md`, `docs/decisions/per-user-api-keys.md`).
- Learn content per user ships L1 to L5 with deploy gates
  (`docs/decisions/learn-content-per-user.md`). L1's migration can be
  reverted only until L2 ships: its `down` refuses once any
  `concept_references` or `recognition_guides` row has a `user_id`, and
  after that the rollback floor is L2's code. L4's copy
  (`CopySharedLearnContent`) has a deploy gate, stated in step 5 of that
  doc. The schema step after L5 (delete shared rows, drop the partial
  indexes, make `user_id` NOT NULL) waits until L5 runs on web and worker,
  as step 6 states.
- Never rename a migration that has been pushed: the PR app has already run
  it under its old version (see "The preview migration version is
  reconciled" in `docs/decisions/tracks.md`).

## What Still Needs Work
1. ~~Email (login code emails won't work yet)~~ — production delivers via Resend's HTTP API (`delivery_method = :resend`; Railway blocks SMTP below Pro). Needs `RESEND_API_KEY`, `MAIL_FROM`, `APP_HOST` on both Railway services: see `docs/deploy/railway-smtp-setup.md`. Sending to teammates requires a verified domain in Resend.
2. ~~`config/environments/production.rb`~~ — done. Resend delivery, `default_url_options`, and `raise_delivery_errors` are wired up from `ENV`.
3. ~~`db:migrate` on Railway~~ — done. `railway.toml` now runs `bundle exec rails db:migrate` via `preDeployCommand` on every deploy, before the new version takes traffic.
4. **Seed a first user**: After deploy, run `rails console` on Railway and create the first user manually, then invite teammates.
5. ~~Remove `/test_login` after buying a domain~~ — done. The route, `SessionsController#test_login`, and ~~`spec/requests/test_login_spec.rb`~~ have been deleted; the `TEST_LOGIN_SECRET` env var can be unset on Railway if still present.
