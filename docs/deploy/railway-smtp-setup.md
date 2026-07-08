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
