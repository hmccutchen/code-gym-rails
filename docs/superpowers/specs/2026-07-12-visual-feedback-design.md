# Visual feedback during exercise generation

## Problem

Today, generating an exercise set has zero live feedback:

- **Initial/on-demand generation** (`DashboardController#show` enqueues `GenerateDailyExercisesJob` when no exercise exists yet for today): the page shows a static "Generating your personalized exercise set… Refresh in a moment" message. The user has to manually refresh and guess whether it's done.
- **Regenerate** (`DailyExercisesController#regenerate`): fully synchronous — calls `AiService` directly in the request/response cycle (~10s), then redirects. The button gives no indication anything is happening while the browser is blocked.
- **On-demand generation has no weekday guard.** The cron schedule (`config/recurring.yml`, `0 8 * * 1-5`) only runs Mon–Fri, but the on-demand trigger in `DashboardController#show` has no day-of-week check at all — opening the dashboard on a weekend silently enqueues generation and burns API usage on a day the team doesn't intend to run exercises.

## Goals

1. Initial/on-demand generation updates the page live via Turbo Stream broadcast — no manual refresh, and a friendly error state (with retry) if generation fails.
2. Regenerate gets a spinner/disabled-button state while the (still synchronous) request is in flight.
3. On-demand generation stops auto-triggering on weekends, but a user can still manually request one on a weekend if they want.

## Non-goals / out of scope

- No changes to magic-link auth, Resend/SMTP, `/test_login`, the feedback UI, the regenerate-button/multi-provider feature, or the email/history-page spec.
- Regenerate stays synchronous — not converting it to a background job.
- No new retry endpoint — retry reuses the existing dashboard GET.
- No JS/system test tooling added — this app has no Capybara/JS driver today and none is being introduced for this feature.

## Architecture

The app has `solid_cable` in the `Gemfile` and its `solid_cable_messages` table already in `db/schema.rb`, but ActionCable itself is not wired up (no `app/channels/`, not mounted in routes, no `allowed_request_origins`). This feature wires it up for the first time:

- `app/channels/application_cable/connection.rb` — identifies the socket's user via `request.session[:user_id]` (the app uses Rails' default cookie session store, so the same signed/encrypted session cookie used for HTTP requests is readable during the WebSocket handshake; no new auth token scheme needed). Rejects the connection if there's no logged-in user.
- `config/routes.rb` — `mount ActionCable.server => "/cable"`.
- `config/environments/production.rb` — `config.action_cable.allowed_request_origins`, reusing the existing `APP_HOST` env var (same one already used for mailer `default_url_options`).
- No new gems, no Redis. Same Puma web dyno; pub/sub is Postgres-backed via `solid_cable`, consistent with the rest of the stack (Solid Queue for jobs).
- Broadcasting uses Turbo Rails' built-in `Turbo::StreamsChannel` (already provided by the `turbo-rails` gem, v2.0.23) via `turbo_stream_from` in the view and `Turbo::StreamsChannel.broadcast_replace_to` in the job — no custom channel class needed beyond the `ApplicationCable::Connection` auth above.

## Weekday guard for on-demand generation

`DashboardController#show`'s on-demand trigger only fires automatically on weekdays:

```ruby
def show
  @exercise = current_user.daily_exercises.for_date.first
  @response = ...

  return unless @exercise.nil? && current_user.api_key_present?

  if flash[:generating]
    @generating = true
  elsif Date.current.on_weekday?
    GenerateDailyExercisesJob.perform_later(user_id: current_user.id)
    @generating = true
  else
    @weekend_no_exercise = true
  end
end
```

- Weekdays: unchanged behavior — auto-enqueue, show the "generating" state.
- Weekends: no auto-enqueue. Shows a new `_weekend_empty` state: "No exercises are generated automatically on weekends — the morning job runs Monday–Friday." plus a "Generate today's set anyway" button.
- That button posts to a new route, `POST /generate` → `DailyExercisesController#generate`:

```ruby
def generate
  return redirect_to root_path if current_user.daily_exercises.for_date.exists?
  GenerateDailyExercisesJob.perform_later(user_id: current_user.id)
  redirect_to root_path, flash: { generating: true }
end
```

`flash[:generating]` survives exactly the one redirect back to `#show`, so the dashboard renders the "generating" state immediately without a second, duplicate enqueue. This is a manual trigger only — it does not affect the existing `regenerate` action, which stays available every day (weekday or weekend) exactly as it is today.

## Broadcast structure (initial/on-demand generation)

- `show.html.erb` adds `<%= turbo_stream_from current_user %>` once near the top, and wraps the existing state markup in `<div id="dashboard-content">...</div>` — this becomes the broadcast replacement target.
- The three existing states plus one new one are each extracted into partials:
  - `dashboard/_generating` — today's existing "Generating…" message (extracted as-is).
  - `dashboard/_weekend_empty` — new; the weekend no-auto-generate message + manual "Generate today's set anyway" button described above.
  - `dashboard/_exercise` — today's big `else` branch (regenerate button, progress bar, three sections, submit, post-submission content), extracted as-is with `exercise:`/`response:` locals.
  - `dashboard/_generation_failed` — new; friendly error message + a plain link back to `root_path` to retry.
- `GenerateDailyExercisesJob#generate_for`:
  - On success (after `DailyExercise.create!`), broadcasts:
    ```ruby
    Turbo::StreamsChannel.broadcast_replace_to(
      user, target: "dashboard-content",
      partial: "dashboard/exercise",
      locals: { exercise: exercise, response: DailyResponse.new(user: user, daily_exercise: exercise, date: Date.current) }
    )
    ```
  - In the existing `rescue AiService::Error => e` branch, in addition to the existing log line, broadcasts:
    ```ruby
    Turbo::StreamsChannel.broadcast_replace_to(
      user, target: "dashboard-content",
      partial: "dashboard/generation_failed", locals: { message: e.message }
    )
    ```
  - Both cron-triggered (batch, no `user_id`) and on-demand (single `user_id`) runs go through the same `generate_for(user)` method and the same two broadcast call sites — no per-trigger-type branching needed.
- Unexpected (non-`AiService::Error`) exceptions are untouched — they still propagate to Solid Queue's normal job-failure handling; no broadcast, no change to retry semantics. Out of scope for this feature.

## Regenerate spinner (stays synchronous)

- New Stimulus controller, `app/javascript/controllers/regenerate_controller.js`, attached to the existing `button_to` form for "Generate new set".
- On `turbo:submit-start`: disables the button and swaps its label to "Generating…" (plus a small CSS spinner).
- On `turbo:submit-end`: restores the button (covers the failure-redirect path; on success the page navigates away before this matters).
- Purely a client-side affordance — no controller/backend changes to `regenerate`.

## Testing

Matches this app's existing conventions (RSpec request/job specs, no Capybara/JS driver):

- `generate_daily_exercises_job_spec.rb`: mock `Turbo::StreamsChannel.broadcast_replace_to` (same style as the existing `allow(AiService).to receive(:for)` mocking) to assert the right partial/target broadcasts on both success and `AiService::Error` failure.
- `dashboard_spec.rb`: use `travel_to` (already available via `ActiveSupport::Testing::TimeHelpers`) to simulate a Saturday/Sunday vs. a weekday, asserting the job is/isn't enqueued (`ActiveJob::TestHelper`) and the right partial renders (`_generating` vs `_weekend_empty`).
- New `daily_exercises_spec.rb` case for `POST /generate`: asserts it enqueues the job and redirects with the generating flash, and is a no-op redirect if today's exercise already exists (e.g., a duplicate click).
- Stimulus spinner behavior is not unit-tested — verified manually in dev; this app has no JS/system test tooling and none is being added for this feature.
