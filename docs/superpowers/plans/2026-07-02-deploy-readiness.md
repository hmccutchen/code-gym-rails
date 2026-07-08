# Deploy Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close out three of the four "What Still Needs Work" items in `CLAUDE.md` — production mailer SMTP config, automatic `db:migrate` on Railway deploy, and a documented, runnable path for setting the live Railway SMTP env vars.

**Architecture:** Two small Rails config changes (`app/mailers/application_mailer.rb`, `config/environments/production.rb`) read mail settings from `ENV` instead of hardcoded placeholders. `railway.toml` gets a `preDeployCommand` so migrations run once per deploy, in a separate pre-traffic container, rather than on every server boot. A new `docs/deploy/railway-smtp-setup.md` gives exact `railway` CLI commands (plus a dashboard fallback) for the user to run themselves against the live `zesty-enthusiasm` project — no live-infra changes happen in this plan.

**Tech Stack:** Rails 8.0.5 `ActionMailer`, Railway config-as-code (`railway.toml`), Railway CLI (`railway variable set`).

## Global Constraints

- Do not touch item 4 ("Seed a first user") from `CLAUDE.md` — out of scope per the approved spec.
- No test/ or spec/ directory exists in this repo (confirmed: zero automated tests currently). Do not introduce a test framework as a side effect of this plan. Verification uses `bin/rails runner` boot-checks executed directly via Bash instead of a committed test suite — this is a deliberate, scoped choice, not an oversight.
- `config/master.key` and `.env*` are gitignored and already present on disk locally — verification commands below rely on `config/master.key` existing in the working directory (it does; do not create or commit one).
- Railway's field is `preDeployCommand` (confirmed against `docs.railway.com/reference/config-as-code`), **not** `releaseCommand` — that is Heroku's term and Railway would silently ignore it (unknown TOML keys are ignored, not errors), so migrations would silently never run. Do not use `releaseCommand`.
- The Railway CLI variable command is singular: `railway variable set`, **not** `railway variables set` (confirmed against `docs.railway.com/cli/variable`).
- Nothing in this plan runs commands against the live Railway project (`zesty-enthusiasm`, ID `5b53ac62-bdb2-4e8d-a7f2-7a457b06ba4e`) or requires Railway CLI credentials in this environment — Task 3's deliverable is a doc the user runs themselves.

---

### Task 1: Production mailer config (SMTP settings, from address, URL host)

**Files:**
- Modify: `app/mailers/application_mailer.rb`
- Modify: `config/environments/production.rb:56-70`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `ActionMailer::Base.smtp_settings`, `ActionMailer::Base.default_url_options`, and `ApplicationMailer`'s default `from` all become `ENV`-driven. Task 3's doc assumes these exact var names exist and are read here: `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `MAIL_FROM`, `APP_HOST`.

- [ ] **Step 1: Confirm current (broken) behavior — run the boot-check against the unmodified files**

```bash
RAILS_ENV=production \
SECRET_KEY_BASE=$(openssl rand -hex 64) \
DATABASE_URL="postgres://localhost/dummy_db_for_boot_check" \
RAILS_MASTER_KEY=$(cat config/master.key) \
CODE_GYM_RAILS_DATABASE_PASSWORD=dummy \
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=abcdefghijklmnopqrstuvwx1234 \
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=abcdefghijklmnopqrstuvwx1234 \
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=abcdefghijklmnopqrstuvwx1234 \
APP_HOST="https://web-production-246e40.up.railway.app" \
MAIL_FROM="code-gym@example.com" \
SMTP_HOST="smtp.resend.com" \
SMTP_PORT="587" \
SMTP_USERNAME="resend" \
SMTP_PASSWORD="secret" \
bundle exec rails runner -e production '
puts "smtp_settings: #{ActionMailer::Base.smtp_settings.inspect}"
puts "default_url_options: #{ActionMailer::Base.default_url_options.inspect}"
puts "from: #{ActionMailer::Base.default_params[:from]}"
puts "raise_delivery_errors: #{ActionMailer::Base.raise_delivery_errors}"
'
```

Expected (RED — confirms the gap this task fixes):
```
smtp_settings: {}
default_url_options: {:host=>"example.com"}
from: from@example.com
raise_delivery_errors: false
```

`smtp_settings` is empty (no SMTP server configured), `default_url_options` is hardcoded to `example.com` instead of the real Railway host, `from` ignores `MAIL_FROM` entirely, and delivery errors are swallowed silently.

- [ ] **Step 2: Update `ApplicationMailer` to read `MAIL_FROM` from `ENV`**

Replace the full contents of `app/mailers/application_mailer.rb`:

```ruby
class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "from@example.com")
  layout "mailer"
end
```

- [ ] **Step 3: Update `config/environments/production.rb`**

Replace this block (lines 56-70):

```ruby
  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }
```

with:

```ruby
  # Raise delivery errors so failed sends surface as failed/retried Solid Queue jobs
  # (UserMailer.magic_link is sent via deliver_later) instead of failing silently.
  config.action_mailer.raise_delivery_errors = true

  # Set host to be used by links generated in mailer templates (e.g. the magic link
  # verify_auth_url). Mailer views render outside the request cycle, so config.force_ssl
  # has no effect here -- protocol is forced to https explicitly.
  app_host = URI.parse(ENV.fetch("APP_HOST", "https://example.com"))
  config.action_mailer.default_url_options = { host: app_host.host, protocol: "https" }

  # Outgoing SMTP server, configured via Railway env vars (see docs/deploy/railway-smtp-setup.md).
  config.action_mailer.smtp_settings = {
    address:              ENV["SMTP_HOST"],
    port:                 ENV["SMTP_PORT"]&.to_i,
    user_name:            ENV["SMTP_USERNAME"],
    password:             ENV["SMTP_PASSWORD"],
    authentication:       :plain,
    enable_starttls_auto: true
  }
```

- [ ] **Step 4: Re-run the same boot-check to confirm it's fixed (GREEN)**

```bash
RAILS_ENV=production \
SECRET_KEY_BASE=$(openssl rand -hex 64) \
DATABASE_URL="postgres://localhost/dummy_db_for_boot_check" \
RAILS_MASTER_KEY=$(cat config/master.key) \
CODE_GYM_RAILS_DATABASE_PASSWORD=dummy \
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=abcdefghijklmnopqrstuvwx1234 \
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=abcdefghijklmnopqrstuvwx1234 \
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=abcdefghijklmnopqrstuvwx1234 \
APP_HOST="https://web-production-246e40.up.railway.app" \
MAIL_FROM="code-gym@example.com" \
SMTP_HOST="smtp.resend.com" \
SMTP_PORT="587" \
SMTP_USERNAME="resend" \
SMTP_PASSWORD="secret" \
bundle exec rails runner -e production '
puts "smtp_settings: #{ActionMailer::Base.smtp_settings.inspect}"
puts "default_url_options: #{ActionMailer::Base.default_url_options.inspect}"
puts "from: #{ActionMailer::Base.default_params[:from]}"
puts "raise_delivery_errors: #{ActionMailer::Base.raise_delivery_errors}"
'
```

Expected (GREEN):
```
smtp_settings: {:address=>"smtp.resend.com", :port=>587, :user_name=>"resend", :password=>"secret", :authentication=>:plain, :enable_starttls_auto=>true, :open_timeout=>5, :read_timeout=>5}
default_url_options: {:host=>"web-production-246e40.up.railway.app", :protocol=>"https"}
from: code-gym@example.com
raise_delivery_errors: true
```

- [ ] **Step 5: Confirm development boot still works unaffected (letter_opener has no SMTP config)**

```bash
bin/rails runner 'puts ActionMailer::Base.default_params[:from]; puts ActionMailer::Base.delivery_method'
```

Expected:
```
from@example.com
letter_opening
```

(No `MAIL_FROM` is set locally, so it falls back to the literal default — dev mail still opens in the browser via `letter_opener`, unaffected by the production SMTP config.)

- [ ] **Step 6: Commit**

```bash
git add app/mailers/application_mailer.rb config/environments/production.rb
git commit -m "$(cat <<'EOF'
Wire up production SMTP config from ENV vars

smtp_settings, default_url_options, and the mailer from-address now read
SMTP_HOST/SMTP_PORT/SMTP_USERNAME/SMTP_PASSWORD/APP_HOST/MAIL_FROM instead
of hardcoded example.com placeholders. raise_delivery_errors is now true so
magic-link send failures surface as failed Solid Queue jobs instead of
disappearing silently.
EOF
)"
```

---

### Task 2: Run `db:migrate` automatically on Railway deploy

**Files:**
- Modify: `railway.toml`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing consumed by later tasks — this is a standalone deploy-config change.

- [ ] **Step 1: Confirm current file has no pre-deploy migration step**

```bash
cat railway.toml
```

Expected (RED — confirms the gap):
```toml
[build]
builder = "nixpacks"

[deploy]
startCommand = "bundle exec rails server -b 0.0.0.0 -p $PORT"
healthcheckPath = "/up"
healthcheckTimeout = 30

[[services]]
name = "web"

[[services]]
name = "worker"
startCommand = "bundle exec rake solid_queue:start"
```

No `preDeployCommand` exists — on Railway's very first deploy (and every deploy that includes a pending migration), `db:migrate` never runs.

- [ ] **Step 2: Add `preDeployCommand` to the `[deploy]` block**

Replace the full contents of `railway.toml`:

```toml
[build]
builder = "nixpacks"

[deploy]
startCommand = "bundle exec rails server -b 0.0.0.0 -p $PORT"
# Runs once per deploy, in a separate container, before the new version takes traffic.
# This is Railway's actual field name -- "releaseCommand" (Heroku's term) does not exist
# in Railway's schema and would be silently ignored.
preDeployCommand = ["bundle exec rails db:migrate"]
healthcheckPath = "/up"
healthcheckTimeout = 30

[[services]]
name = "web"

[[services]]
name = "worker"
startCommand = "bundle exec rake solid_queue:start"
```

- [ ] **Step 3: Verify the change landed correctly**

```bash
grep -A1 'startCommand = "bundle exec rails server' railway.toml
```

Expected (GREEN):
```
startCommand = "bundle exec rails server -b 0.0.0.0 -p $PORT"
# Runs once per deploy, in a separate container, before the new version takes traffic.
```

```bash
grep -F 'preDeployCommand = ["bundle exec rails db:migrate"]' railway.toml
```

Expected: the line prints (grep exits 0).

Note: this repo has no TOML parser available locally (no `tomllib` in the system Python 3.9, no TOML gem in `Gemfile.lock`) to do a full syntax validation. The structural check above plus matching Railway's documented example format is the extent of local verification — final confirmation is an actual Railway deploy showing a pre-deploy step in the deployment logs, which is outside this plan's reach.

- [ ] **Step 4: Commit**

```bash
git add railway.toml
git commit -m "$(cat <<'EOF'
Run db:migrate automatically via Railway preDeployCommand

Migrations now run once per deploy in a separate pre-traffic container,
instead of never running (there was no migration step at all before this).
EOF
)"
```

---

### Task 3: Railway SMTP env var setup doc

**Files:**
- Create: `docs/deploy/railway-smtp-setup.md`
- Modify: `CLAUDE.md` (update "What Still Needs Work" section)

**Interfaces:**
- Consumes: the exact env var names from Task 1 (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `MAIL_FROM`, `APP_HOST`) and the finding that `UserMailer.magic_link` is sent via `deliver_later` (delivery executes in the `worker` service, per `app/controllers/sessions_controller.rb:23`).
- Produces: nothing consumed by other tasks — this is a doc-only deliverable for the user to act on outside this plan.

- [ ] **Step 1: Create `docs/deploy/railway-smtp-setup.md`**

```markdown
# Setting SMTP env vars on Railway

Magic-link emails (`UserMailer.magic_link`) are sent via `deliver_later`, so
actual SMTP delivery happens inside the **worker** service (Solid Queue), not
`web`. `web` still needs the same vars at boot, since
`config.action_mailer.default_url_options` (in `config/environments/production.rb`)
reads `APP_HOST` during `eager_load`. Set all six vars on **both** services.

## Vars to set

| Var | Value |
|---|---|
| `SMTP_HOST` | `smtp.resend.com` |
| `SMTP_PORT` | `587` |
| `SMTP_USERNAME` | `resend` (literal string — Resend's SMTP gateway uses this as a routing marker, not an account username) |
| `SMTP_PASSWORD` | your Resend API key (starts with `re_`) |
| `MAIL_FROM` | a sender address on a domain you've verified in Resend, e.g. `code-gym@yourcompany.com` |
| `APP_HOST` | `https://web-production-246e40.up.railway.app` |

Resend also supports port `465` (SSL/TLS) — if you use that instead of `587`,
you'd need to also change `config/environments/production.rb`'s
`smtp_settings` (`enable_starttls_auto: true` assumes STARTTLS on `587`, not
implicit TLS on `465`). Stick with `587` unless you've made that change.

You must verify at least one sending domain in Resend before any email will
actually send — see https://resend.com/domains. This is a one-time step in
the Resend dashboard, not something in this repo.

## Option A: Railway CLI

```bash
# One-time setup, if not already done:
brew install railway   # or: curl -fsSL https://railway.com/install.sh | sh
railway login
railway link            # select the "zesty-enthusiasm" project when prompted

# Set on the web service (confirm your environment name with `railway environment` --
# most single-environment Railway projects call it "production"):
railway variable set -s web -e production \
  SMTP_HOST=smtp.resend.com \
  SMTP_PORT=587 \
  SMTP_USERNAME=resend \
  SMTP_PASSWORD=re_your_actual_key \
  MAIL_FROM=code-gym@yourcompany.com \
  APP_HOST=https://web-production-246e40.up.railway.app

# Set on the worker service (this is where delivery actually happens):
railway variable set -s worker -e production \
  SMTP_HOST=smtp.resend.com \
  SMTP_PORT=587 \
  SMTP_USERNAME=resend \
  SMTP_PASSWORD=re_your_actual_key \
  MAIL_FROM=code-gym@yourcompany.com \
  APP_HOST=https://web-production-246e40.up.railway.app
```

Each `railway variable set` triggers a redeploy of that service by default.

## Option B: Railway dashboard

1. Open the `zesty-enthusiasm` project: https://railway.app/project/5b53ac62-bdb2-4e8d-a7f2-7a457b06ba4e
2. Click the **web** service → **Variables** tab → **Raw Editor** → paste the six vars above (with real values) → **Save**.
3. Repeat step 2 for the **worker** service.
4. Confirm both services redeploy successfully after saving.

## Verifying it worked

After both services redeploy, log into the app and request a magic link.
Check the **worker** service's logs (`railway logs -s worker`) for the
Solid Queue job completing without an SMTP error. If `SMTP_PASSWORD` or
`SMTP_HOST` is wrong, `raise_delivery_errors = true` (set in Task 1) means
the job will show as failed in Solid Queue rather than silently vanishing.
```

- [ ] **Step 2: Update `CLAUDE.md`'s "What Still Needs Work" section**

Replace:

```markdown
## What Still Needs Work

1. **Email (magic links won't work yet)**: Need to set SMTP env vars in Railway. Recommended: [Resend](https://resend.com) (free tier). Add to Railway env vars: `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `MAIL_FROM`, `APP_HOST`.
2. **`config/environments/production.rb`**: Add SMTP config (see `.env.example` for the keys).
3. **`db:migrate` on Railway**: First deploy needs `rails db:migrate` to run. Add `bundle exec rails db:migrate &&` before the start command, or use a Railway deploy command.
4. **Seed a first user**: After deploy, run `rails console` on Railway and create the first user manually, then invite teammates.
```

with:

```markdown
## What Still Needs Work

1. ~~Email (magic links won't work yet)~~ — `production.rb` and `ApplicationMailer` now read SMTP settings from `ENV`. You still need to set the actual values on the live Railway project: see `docs/deploy/railway-smtp-setup.md`.
2. ~~`config/environments/production.rb`~~ — done. `smtp_settings`, `default_url_options`, and `raise_delivery_errors` are wired up from `ENV`.
3. ~~`db:migrate` on Railway~~ — done. `railway.toml` now runs `bundle exec rails db:migrate` via `preDeployCommand` on every deploy, before the new version takes traffic.
4. **Seed a first user**: After deploy, run `rails console` on Railway and create the first user manually, then invite teammates.
```

- [ ] **Step 3: Verify the doc reads correctly and CLAUDE.md diff is as expected**

```bash
cat docs/deploy/railway-smtp-setup.md
git diff CLAUDE.md
```

Expected: the doc renders as valid markdown (headings, table, two fenced code blocks), and the `CLAUDE.md` diff shows only items 1-3 struck through/marked done, item 4 unchanged.

- [ ] **Step 4: Commit**

```bash
git add docs/deploy/railway-smtp-setup.md CLAUDE.md
git commit -m "$(cat <<'EOF'
Add Railway SMTP env var setup doc; mark items 1-3 done in CLAUDE.md

Documents exact CLI commands and a dashboard fallback for setting SMTP vars
on both the web and worker services (delivery happens in worker, since
magic-link mail is sent via deliver_later). Actually running these commands
against the live Railway project is left to the user.
EOF
)"
```
