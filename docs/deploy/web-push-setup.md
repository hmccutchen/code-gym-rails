# Daily reminder push notifications (Web Push / VAPID)

The morning reminder is sent from `SendPushReminderJob`, which runs in the
**worker** service — but the VAPID **public** key is rendered into every page
by `web`, so both services need the vars below. Until they are set,
`WebPushCredentials.configured?` is false: the Account page shows no reminder
control, the layout emits no push script, `POST /push_subscription` 404s, and
the job returns without contacting a push service. Nothing half-works.

## Generating a keypair

Once, from any checkout:

```bash
bin/rails runner 'require "web_push"; k = WebPush.generate_key; puts "VAPID_PUBLIC_KEY=#{k.public_key}"; puts "VAPID_PRIVATE_KEY=#{k.private_key}"'
```

Keep the pair stable. Rotating it invalidates every subscription already
issued: existing endpoints keep 201-ing but silently stop being delivered, and
every user has to turn reminders on again from the device. If you do rotate,
clear the `push_subscriptions` table in the same deploy so the launch
re-subscribe re-registers everyone rather than leaving dead rows behind.

## Vars to set

| Var | Value |
|---|---|
| `VAPID_PUBLIC_KEY` | public half from the command above |
| `VAPID_PRIVATE_KEY` | private half — secret, worker only in principle, but `web` reading it is harmless and keeps the two services' config identical |
| `VAPID_SUBJECT` | optional. `mailto:` or `https:` contact for whoever operates the deployment. Defaults to `mailto:$MAIL_FROM` |

Set them on **both** `web` and `worker`.

`railway variable set` redeploys **the service it targets**. So the usual
"`--skip-deploys` on everything but the last call" shortcut redeploys only that
one service; the other keeps running its old environment. A `web` that never
restarted renders no reminder control while every variable still reads back as
correctly set, which sends you looking at the variables — the one place the
problem isn't. Skip deploys on all but the *final call for each service*:

```bash
railway login
railway link   # the "Code Gym" project, production environment

railway variable set VAPID_PUBLIC_KEY=<public> --service web    --skip-deploys
railway variable set VAPID_PUBLIC_KEY=<public> --service worker --skip-deploys

# Read the private half into a variable rather than typing it into the command:
# -s doesn't echo it, and the shell records the variable name, not the value.
# Pasting it as a literal argument here would put it in your history instead.
read -rs VAPID_PRIVATE

# No --skip-deploys on either of these, so each service gets exactly one deploy.
printf %s "$VAPID_PRIVATE" | railway variable set VAPID_PRIVATE_KEY --stdin --service web
printf %s "$VAPID_PRIVATE" | railway variable set VAPID_PRIVATE_KEY --stdin --service worker
unset VAPID_PRIVATE
```

`variable` is the canonical subcommand on CLI v5.x and what the examples above
use; `variables`, `vars` and `var` are registered aliases, so older writeups
using the plural still run. The form that is genuinely legacy is
`railway variables --set "KEY=VALUE"`, which the CLI's own help flags as
superseded by `variable set`.

Confirm each service actually restarted rather than trusting the variable list:

```bash
railway deployment list --service web    --json | jq '.[0] | {status, createdAt}'
railway deployment list --service worker --json | jq '.[0] | {status, createdAt}'
```

Both deployments must be newer than the variable set, and `SUCCESS`.

## What users have to do

Turning reminders on is one tap on the Account page, and it must happen on the
device that will receive them — a permission grant is per-browser, so a
laptop and a phone each need their own.

**On iPhone and iPad it only works from a Home Screen app.** Safari does not
expose `window.PushManager` in an ordinary tab, so the Account page disables
the control and says so. The user must open Share → Add to Home Screen, launch
Code Gym from that icon, and turn reminders on there.

## If a teammate can't enrol

`PushSubscriptionsController::ALLOWED_ENDPOINT_HOSTS` holds enrolment to the
push services browsers actually use (FCM, Mozilla, Apple, WNS), matched by
domain suffix. That closes an otherwise-blind SSRF: without it, any logged-in
teammate could store an arbitrary URL that the worker POSTs to every morning
from inside the deployment's network.

The cost is that a browser using a service the list doesn't name cannot turn
reminders on. That is visible rather than silent — the Account page shows the
error, and the server logs `refused enrolment for unrecognised push host:` with
the host. Add the host to the constant if it is legitimate.

## Reliability, honestly

Web push on iOS is materially less reliable than native push, and this is a
platform limit rather than something the implementation above fixes:

- Subscriptions are dropped by iOS on their own — after a stretch of
  inactivity, and sometimes for no visible reason. Delivery rates well below
  native are widely reported, and push that worked for weeks can stop with no
  error anywhere.
- The recovery a user is often left with is toggling notifications off and on
  in iOS Settings, or removing and re-adding the Home Screen app.

Two mitigations are built in. `PushDelivery` deletes an endpoint the moment a
push service reports it gone (404/410), so the job stops pushing at dead
addresses. And every page load re-subscribes and re-registers the endpoint
(`shared/_push_script`), which repairs a silently-rotated subscription without
the user noticing anything.

**The second one has a hole worth knowing about:** it only helps someone who
still opens the app. A user who has drifted away — precisely the person the
reminder exists for — generates no page load for it to run in, so their
endpoint stays dead and the reminders stay silent. On desktop and Android
none of this applies; those endpoints are stable.
