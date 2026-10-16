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
  - "app/services/schema_wait.rb"
  - "db/migrate/**"
---

# Railway deployment


- Project: `zesty-enthusiasm` (ID: `5b53ac62-bdb2-4e8d-a7f2-7a457b06ba4e`)
- Web service: `web-production-246e40.up.railway.app`
- Services: web, worker, postgres
- Web start command: `bundle exec puma -C config/puma.rb` (set in `railway.toml`; don't use `rails server -p $PORT` — Railway start commands run in exec form, so `$PORT` is never shell-expanded, while puma reads `PORT` from ENV)
- Worker start command: `bundle exec rake solid_queue:start` (set in `railway.worker.toml`; the worker service's Settings → Config-as-code file path must point at `/railway.worker.toml`, otherwise it inherits the web config and fails healthchecks)
- Worker pre-deploy: `bundle exec rails db:wait_for_schema` (`SchemaWait`). Railway starts web and worker concurrently and orders neither, so on a PR app — where the database starts empty — a worker that wins the race dies on boot reading `solid_queue_recurring_tasks`. It waits rather than migrating: migrations keep one owner (the web pre-deploy), because `db:migrate` against an empty database performs an *unlocked schema load*, so a second migrator races and the loser dies on a duplicate constraint
- Database pool: `config/database.yml` takes its size from `DatabasePool.size` (`lib/boot/database_pool.rb`), the larger of `RAILS_MAX_THREADS` (default 5) and what one Solid Queue worker process can need while judging: a connection per worker thread in `config/queue.yml`, one more per section for each of those threads' judge fan-out (`DatabasePool::SECTIONS_PER_DAY`, restated because `database.yml` is read before `app/` loads, and held equal to `ExerciseSection::MAX_SECTIONS` by a spec), and two for Solid Queue's polling and heartbeat — 17 today. Nothing needs setting on Railway, and `spec/lib/database_pool_spec.rb` fails if the pool falls below that sum. Connections open only when a thread asks for one, so the web service, which reads the same file, opens none of the extra ceiling unless it uses them. The sizing is so the fan-out never waits for a connection: each judge and retry thread checks one out only to write its `ApiUsage` row, and a pool too small for them would make that write wait out the checkout timeout
- Env vars already set in Railway: `RAILS_ENV`, `RAILS_MASTER_KEY`, all three `ACTIVE_RECORD_ENCRYPTION_*` keys, `DATABASE_URL` (references postgres service)

## Migrations

- The worker's pre-deploy waits for a schema, not for pending migrations, so
  a new column ships a release before any code reads it, and a column being
  removed is ignored by the model for one release before a migration drops
  it (`docs/decisions/tracks.md`, `docs/decisions/per-user-api-keys.md`).
- Never rename a migration that has been pushed: the PR app has already run
  it under its old version (see "The preview migration version is
  reconciled" in `docs/decisions/tracks.md`).

## What Still Needs Work
1. ~~Email (login code emails won't work yet)~~ — production delivers via Resend's HTTP API (`delivery_method = :resend`; Railway blocks SMTP below Pro). Needs `RESEND_API_KEY`, `MAIL_FROM`, `APP_HOST` on both Railway services: see `docs/deploy/railway-smtp-setup.md`. Sending to teammates requires a verified domain in Resend.
2. ~~`config/environments/production.rb`~~ — done. Resend delivery, `default_url_options`, and `raise_delivery_errors` are wired up from `ENV`.
3. ~~`db:migrate` on Railway~~ — done. `railway.toml` now runs `bundle exec rails db:migrate` via `preDeployCommand` on every deploy, before the new version takes traffic.
4. **Seed a first user**: After deploy, run `rails console` on Railway and create the first user manually, then invite teammates.
5. ~~Remove `/test_login` after buying a domain~~ — done. The route, `SessionsController#test_login`, and `spec/requests/test_login_spec.rb` have been deleted; the `TEST_LOGIN_SECRET` env var can be unset on Railway if still present.
