# Email setup on Railway (Resend HTTP API)

> **History:** this doc originally described SMTP env vars. That approach cannot
> work on this project's Railway plan — Railway blocks outbound SMTP (ports
> 25/465/587) on all plans below Pro, so `Net::OpenTimeout` is raised at TCP
> connect. Delivery now goes through Resend's HTTPS API instead
> (`config.action_mailer.delivery_method = :resend`), which works on every plan.

Magic-link emails (`UserMailer.magic_link`) are sent via `deliver_later`, so
delivery happens inside the **worker** service (Solid Queue), not `web`. `web`
still reads `APP_HOST` at boot for mailer link URLs. Set all three vars on
**both** services.

## Vars to set

| Var | Value |
|---|---|
| `RESEND_API_KEY` | your Resend API key (starts with `re_`) |
| `MAIL_FROM` | a sender address on a domain you've verified in Resend — or `onboarding@resend.dev`, which delivers **only to your own Resend account email** (fine for smoke tests, useless for teammates) |
| `APP_HOST` | `https://web-production-246e40.up.railway.app` |

The legacy `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` vars
are no longer read and can be deleted.

To send to anyone other than yourself you must verify a sending domain in
Resend first — see https://resend.com/domains. One-time step in the Resend
dashboard, not something in this repo.

## Option A: Railway CLI

```bash
railway login
railway link   # select the "zesty-enthusiasm" project

railway variable set -s web -e production \
  RESEND_API_KEY=re_your_actual_key \
  MAIL_FROM=code-gym@yourcompany.com \
  APP_HOST=https://web-production-246e40.up.railway.app

railway variable set -s worker -e production \
  RESEND_API_KEY=re_your_actual_key \
  MAIL_FROM=code-gym@yourcompany.com \
  APP_HOST=https://web-production-246e40.up.railway.app
```

Each `railway variable set` triggers a redeploy of that service by default.

## Option B: Railway dashboard

1. Open the `zesty-enthusiasm` project: https://railway.app/project/5b53ac62-bdb2-4e8d-a7f2-7a457b06ba4e
2. Click the **web** service → **Variables** tab → add the three vars → **Save**.
3. Repeat for the **worker** service.
4. Confirm both services redeploy successfully.

## Verifying it worked

After both services redeploy, request a magic link from the login page and
check the worker logs (`railway logs -s worker`). A bad API key or an
unverified `MAIL_FROM` domain surfaces as a failed Solid Queue job
(`raise_delivery_errors = true`), not silence. Remember that with
`onboarding@resend.dev` as `MAIL_FROM`, only the Resend account owner's email
actually receives anything.
