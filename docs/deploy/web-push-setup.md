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

## What users have to do

Turning reminders on is one tap on the Account page, and it must happen on the
device that will receive them — a permission grant is per-browser, so a
laptop and a phone each need their own.

**On iPhone and iPad it only works from a Home Screen app.** Safari does not
expose `window.PushManager` in an ordinary tab, so the Account page disables
the control and says so. The user must open Share → Add to Home Screen, launch
Code Gym from that icon, and turn reminders on there.

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
