# Pause Automatic Generation — Design

## Problem

Users on a free-tier AI provider key (e.g. Gemini's free tier) can burn through
rate/quota limits from the unattended 8am weekday cron job even during
stretches when they aren't actively using the app. There's currently no way
for a user to stop that automatic generation short of removing their API key
entirely (which would also block the on-demand generation they still want
when they do open the app).

## Goal

Let a user pause automatic (cron-triggered) daily exercise generation,
independent of on-demand generation, until they manually resume it.

## Scope

- A user-controlled pause/resume toggle on `/account`.
- The toggle affects only `GenerateDailyExercisesJob`'s unattended batch path
  (the 8am weekday cron, run with no `user_id`).
- On-demand generation — triggered by opening the dashboard on a day with no
  exercise yet, or the weekend "generate anyway" button (`POST /generate`) —
  is **not** affected by the pause. A paused user opening the app still gets
  today's exercise generated normally.
- Pausing is indefinite: it stays in effect until the user manually resumes
  it. No auto-expiry, no "resume on this date" scheduling.
- Out of scope: pausing/resuming for other users (e.g. admin-initiated),
  auto-pausing in response to observed rate-limit errors, any change to
  `regenerate`'s once-daily cap, or to `last_generation_error`/
  `last_generation_error_date` handling.

## Data model

Add `paused_generation_at` (timestamp, nullable) to `users`:

- `nil` — automatic generation is active (default/current behavior).
- non-nil — automatic generation is paused; the timestamp records when the
  user paused it (available for display, e.g. "paused since July 29").

A timestamp is used instead of a boolean because it's the same cost to add
and store, and gives "paused since" for free if the account page wants to
surface it — no separate `paused_generation: boolean` needed.

## Job change

`GenerateDailyExercisesJob#perform`'s unattended batch path (the `else`
branch, invoked with no `user_id` by the recurring cron):

```ruby
User.active.where.not(api_key: nil).where(paused_generation_at: nil).find_each do |user|
  Time.use_zone(user.effective_time_zone) { generate_if_due(user) }
end
```

The on-demand path (`user_id:` present) is unchanged — it doesn't consult
`paused_generation_at` at all, per the scope above.

## Controller / route

New action on the existing `AccountsController`:

- `PATCH /account/toggle_generation` → `AccountsController#toggle_generation`
- Flips `paused_generation_at`: sets it to `Time.current` if currently `nil`,
  clears it to `nil` otherwise.
- Redirects to `/account` with a flash notice: "Automatic daily generation
  paused." or "Automatic daily generation resumed."

Route addition (member action on the existing singular `account` resource):

```ruby
resource :account, only: [ :show, :destroy ] do
  patch :toggle_generation, on: :member
end
```

## View

A new section on `app/views/accounts/show.html.erb`, alongside the existing
log-out/delete controls:

- Current state: "Automatic generation is active" or "Automatic generation is
  paused (since <date>)".
- A single button/form posting to `PATCH /account/toggle_generation`, labeled
  "Pause automatic generation" or "Resume automatic generation" depending on
  current state.

## Edge cases

- Unpausing does not retroactively generate anything for missed days; the
  next cron cycle simply resumes normal `generate_if_due` behavior.
- No interaction with `last_generation_error` / `last_generation_error_date`
  — pausing doesn't clear or set them, and the dashboard's status polling is
  unaffected.
- No interaction with `regenerate`'s once-daily cap.
- Anonymized (`anonymized_at` present) users are already excluded via
  `User.active` before this change; unaffected.

## Testing plan

- **Job spec** (`generate_daily_exercises_job_spec.rb`): a paused user is
  skipped in the unattended batch path (`perform` with no `user_id`), but
  still generates normally via the on-demand path (`perform(user_id:)`).
- **Request spec** (`accounts_spec.rb` or new): `PATCH /account/toggle_generation`
  toggles `paused_generation_at` from `nil` to a timestamp and back, and
  redirects to `/account` with the expected flash notice in each direction.
- Migration itself needs no dedicated test (matches existing convention for
  other nullable timestamp columns on `users`).
