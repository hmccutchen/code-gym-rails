# Deploy Readiness: Mailer Config, DB Migration on Deploy, Railway SMTP Vars

## Context

`CLAUDE.md` lists four items under "What Still Needs Work" before the app is usable in production. This spec covers three of them:

1. Production mailer SMTP config
2. Running `db:migrate` automatically on Railway deploy
3. Setting the actual SMTP env vars on the live Railway project

Seeding the first user (item 4 in CLAUDE.md) is explicitly out of scope for this round.

## 1. Production mailer config

**File:** `config/environments/production.rb`

Currently the file has no `action_mailer` SMTP configuration, and `ApplicationMailer` hardcodes `from: "from@example.com"`. `.env.example` already documents the intended env vars (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `MAIL_FROM`, `APP_HOST`) but nothing reads them yet.

Changes:
- Add `config.action_mailer.smtp_settings`, populated from `ENV["SMTP_HOST"]`, `ENV["SMTP_PORT"]`, `ENV["SMTP_USERNAME"]`, `ENV["SMTP_PASSWORD"]`, with `authentication: :plain` and `enable_starttls_auto: true`.
- Add `config.action_mailer.default_url_options`, derived from `ENV["APP_HOST"]` (a full URL per `.env.example`, e.g. `https://your-app.railway.app`). Parse out the host; force `protocol: "https"` explicitly, since mailer-generated URLs are built outside the request cycle and `config.force_ssl` does not apply to them.
- Add `config.action_mailer.default_options = { from: ENV.fetch("MAIL_FROM", "code-gym@example.com") }`, and update `ApplicationMailer` to drop its hardcoded `from`.
- Set `config.action_mailer.raise_delivery_errors = true`. `UserMailer.magic_link` is sent via `deliver_later`, so delivery happens inside a Solid Queue job — without this, SMTP failures fail silently instead of showing up as a failed/retried job.
- Use `ENV[...]` (not `ENV.fetch` without a default) for the SMTP settings so a missing var doesn't crash boot/eager-load; a misconfigured SMTP setting should fail at send time, not at process start.

## 2. DB migration on deploy

**File:** `railway.toml`

The current `[deploy]` block only starts the server — no migration step runs on deploy:
```toml
[deploy]
startCommand = "bundle exec rails server -b 0.0.0.0 -p $PORT"
healthcheckPath = "/up"
healthcheckTimeout = 30
```

Add a `releaseCommand`, Railway's native pre-traffic release hook (equivalent to Heroku's release phase):
```toml
[deploy]
startCommand = "bundle exec rails server -b 0.0.0.0 -p $PORT"
releaseCommand = "bundle exec rails db:migrate"
healthcheckPath = "/up"
healthcheckTimeout = 30
```

This runs once per deploy, before the new version takes traffic — as opposed to chaining `db:migrate &&` into `startCommand`, which would re-run on every process boot/restart of every instance. `releaseCommand` only applies to the `[[services]] name = "web"` block; the `worker` service's `startCommand` (`bundle exec rake solid_queue:start`) is unaffected.

## 3. Railway SMTP env vars

This is a live-infrastructure action against the Railway project (`zesty-enthusiasm`, ID `5b53ac62-bdb2-4e8d-a7f2-7a457b06ba4e`), not a code change, and there is no Railway CLI or credentials available in this environment. Deliverable: exact commands for the user to run themselves.

Key finding: `UserMailer.magic_link(...).deliver_later` enqueues through Solid Queue, so actual SMTP delivery executes in the **worker** service, not `web`. Vars must be set on `worker` for delivery to work. They're also needed on `web` at boot (eager-loaded `default_url_options`), so the same six vars get set on both services:

`SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `MAIL_FROM`, `APP_HOST`

The plan step will produce:
- `railway variables set` commands scoped to `--service web` and `--service worker`, for the user to run via `!`.
- A dashboard-based fallback (which fields to fill in under each service's Variables tab) in case the user prefers the UI or doesn't have the CLI installed.
- A recommendation to use Resend per CLAUDE.md's suggestion, but the config itself is provider-agnostic — any SMTP provider's credentials work.

## Out of scope

- Seeding the first user (CLAUDE.md item 4).
- Installing/authenticating the Railway CLI on this machine.
- Actually running the `railway variables set` commands — the user runs those themselves.
