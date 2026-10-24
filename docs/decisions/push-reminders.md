# Push reminders

an optional notification each weekday when the day's set
is ready, and an optional afternoon nudge on days it is left unfinished,
turned on and off on the Account page. The nudges switch saves as soon as it
changes, with a `<noscript>` form as the fallback.
The nudge window is `PushNudgePlan::NUDGE_HOURS` (13-17 local, inclusive), so
an unfinished day sends at most five on the hourly cron — a bound that belongs
to the schedule, not to the plan object, which holds no dedupe.

**Submission is the whole stopping rule, and starting is not.** An untouched
day, a half-answered one, and one answered in full but never submitted all
qualify — a set someone got two sections into and walked away from is exactly
what a reminder exists to reach, so going silent the moment anything was
typed left the commonest abandonment unreachable. `SendPushReminderJob` picks
the copy from how far through the day is
(`push_reminder.nudge.titles` in `config/locales/en.yml`), since "still waiting" reads as not
having noticed the half that was done. A partly answered day whose answered
sections are rated gets the ready-to-submit nudge, explicitly naming the
remaining sections as optional. A partly answered, unrated day still gets
the partway nudge; a fully answered, unrated day asks for ratings.
`DailyResponse#submit_blocker` is the one authority for that gate, read by
the dashboard's nudge through each autosave reply, `ResponsesController#create`'s
refusal and, through `#submittable?`, the push nudge,
so a notification can never name a button the user cannot press. Readiness
does not stop nudges: submission and `PushNudgePlan`'s quiet period still do.

**`PushNudgePlan::QUIET_PERIOD` is what keeps that from nagging.** With
starting no longer silencing the day, an hourly tick would otherwise tell
someone mid-answer that they have sections left. A nudge holds off until the
day's `DailyResponse` has been untouched for an hour — its `updated_at`,
which moves only when a save actually changes something, so an idempotent
autosave of unchanged answers doesn't reset it. One hour is what covers a
whole tick of the production schedule, so a save silences the next nudge
whatever minute it landed on; a shorter period would let a save early in the
gap between two ticks be past it by the time the later one ran.
`push_nudge_plan_spec` reads `config/recurring.yml` and fails if that
schedule shortens, rather than leaving the justification to a comment.
Development's five-minute schedule is deliberately not pinned, since a quiet
period spanning several of its ticks breaks nothing.
It delays rather than silences — an abandoned day still qualifies on
every later tick of the window, which is where the five-per-day bound above
still comes from. A day with no response row at all has no activity to be
quiet since, so it nudges from the window's first tick exactly as before.
`WebPushCredentials` is the
single authority for "is push configured here at all" — with no VAPID pair in
ENV the control doesn't render, the layout emits no script, `POST
/push_subscription` 404s and `SendPushReminderJob` returns without contacting
a push service, so an unconfigured deployment offers nothing that could only
fail. Setup and key generation: `docs/deploy/web-push-setup.md`.

**The endpoint is held to a host allowlist at the boundary.**
`PushSubscriptionsController::ALLOWED_ENDPOINT_HOSTS` matches by domain
suffix, because an endpoint is minted by the browser's own push service and
can only come from a known handful of hosts. Without it the stored endpoint
is an arbitrary URL chosen by whoever is logged in, which the worker then
POSTs to on every reminder from inside the deployment's network — a blind,
authenticated SSRF primitive. A refused host is logged with its name, so a
browser using a service the list doesn't yet name is diagnosable rather than
a silent failure to enrol.

**Intent and transport are separate facts, deliberately.**
`User#reminder_level` is the answer to "how much does this person want to
hear from us"; `PushSubscription` rows are the endpoints that can
currently reach them. iOS drops subscriptions on its own, so an endpoint has to be able
to die without taking the user's answer with it — that is what lets the next
launch re-register silently instead of asking again for a permission the
browser already granted. Turning reminders off clears both; anonymizing an
account clears both, since a home-screen install keeps its browser-side
subscription after the account is gone.

**Only Turn on enrolls the account.** Its registration sends `enroll: true`;
page-load registration and "Allow notifications on this device" only repair
transport. Registration and Turn off both hold the user-row lock, so repair
checks the latest intent before writing an endpoint. If Turn off committed
first, repair returns 409 without changing anything; if registration ran
first, Turn off removes its endpoint. Nudges keep their current level.
Missing enrollment flags mean repair, including requests from an older open
page. An old Turn on page therefore needs a reload; treating its unmarked
request as enrollment would reopen the page-load race. An explicit Turn on
can enroll again after Turn off; this does not add a version to arbitrate
competing explicit choices across tabs.

**The setting is one per account; permission is per install.** Removing the
iOS Home Screen app and adding it again (which #373's new icons asked for)
leaves `reminder_level` on but gives the new install no permission, and the
launch re-subscribe cannot ask for one outside a tap, so it fails silently.
The Account page therefore checks this device's `Notification.permission`
while the account is on: `default` shows "Allow notifications on this
device", the same permission request as Turn on, but it registers only this
device (`enroll: false`), so it never changes the level and is refused once
reminders are off; `denied` names the device setting; `granted` shows
nothing, since the launch re-subscribe already registers the endpoint. The
old install's endpoint keeps receiving until Apple refuses it and
`PushDelivery` prunes it.

**Both reminders are enqueued by `GenerateDailyExercisesJob`'s cron branch,
not scheduled on their own.** "It is this user's 8am on a weekday" already
has an owner and a second cron entry would be a second place for it to
drift — and the tick is already hourly, so a nudge needs no new schedule.
That branch's `exists?` check is therefore a fork rather than a gate: the
tick that finds no set generates and sends `:ready`, and later ticks consult
`PushNudgePlan` and may send `:nudge`. What stops the nudge repeating all
day is the user finishing the set, not the hour having passed once. The
on-demand branch still enqueues neither — a user who triggered generation by
opening the dashboard is already looking at the set.

**Intent is a three-value dial, `User#reminder_level`** (`none` / `ready` /
`ready_and_nudges`). `#push_reminders_enabled?` is derived from it rather
than stored, because that name answers transport as well as intent:
`shared/_push_script` uses it to decide whether to mount the `push-launch`
controller that re-subscribes this browser, which the dial does not change.

**The permission call must be the first synchronous statement in the click
handler.** iOS grants a prompt only to a request made synchronously inside a
user gesture and fails *silently* otherwise — no prompt, no console error.
So `accounts/_push_reminders` calls `Notification.requestPermission()` before
anything else, the VAPID public key is rendered into the page rather than
fetched, and the service worker is registered inside the resulting `.then()`.
A request spec pins the key's presence in the page, since that is what
removes the round trip that would otherwise have to precede the call.
Capability is tested as `"PushManager" in window` rather than by sniffing
`display-mode` or an iOS version: on iOS that property is simply absent
outside a Home Screen app, which is the thing actually worth knowing and
stays true however a given release reports itself.

**Accepted limitation, not a defect to perfect away:** web push on iOS is
materially less reliable than native push. Subscriptions are dropped after
inactivity or for no visible reason, delivery rates well below native are
widely reported, and a user's only recovery is often toggling the OS setting
or re-adding the Home Screen app. Two mitigations are built in — `PushDelivery`
prunes an endpoint the moment a push service reports it gone (404/410), and
every page load re-subscribes and re-registers (`shared/_push_script`,
skipping the write when the endpoint is one the server already holds). The
second has a hole that cannot be closed from here: it only repairs the
subscription of someone who still opens the app, and a user who has drifted
away — exactly who the reminder is for — generates no launch for it to run
in. Desktop and Android endpoints are stable and none of this applies to them.
