# Async Regenerate

## Problem

`DailyExercisesController#regenerate` calls `AiService#generate_exercise` inline,
on a request thread, and waits for the whole provider round trip before
redirecting. Generation is the largest single response the app ever asks for —
one non-streaming call carrying every section — so that request holds a Puma
thread for as long as the provider takes.

This surfaced when generation's read budget was separated from the review
budget (PR #72). The worker's generation path can now wait
`AiService::GENERATION_READ_TIMEOUT` (300s), but regenerate could not be given
the same budget without letting a single click pin a Puma thread for five
minutes. It was capped at `SYNC_GENERATION_READ_TIMEOUT` (90s) as a stopgap —
enough room to usually succeed, but still a synchronous provider call in a
controller action, which this project's conventions otherwise prohibit.

The reason regenerate was never made asynchronous is that it has no completion
signal. Both `dashboard/_generating` and `GET /dashboard/status` report
completion by *today's exercise row appearing*. Regenerate replaces that row
**in place**, so the row is present the entire time and the dashboard would
report `ready` immediately.

## Goals

- Regenerate performs no provider I/O on a request thread.
- Regenerate gets the worker's full generation budget.
- A failed regeneration leaves today's problem set intact and does not consume
  the user's once-per-day regenerate.
- While regenerating, the dashboard shows the same spinner as first-time
  generation.

## Non-goals

- Changing `GenerateDailyExercisesJob`, the morning cron, or the first-time
  on-demand generation path beyond the polling window fix below.
- Streaming provider responses.
- Removing `SYNC_GENERATION_READ_TIMEOUT`. It stops being reachable from
  `#regenerate` but stays as the documented budget for any future caller that
  genuinely must block. (See "Open question" below.)

## Design

### State

Add one nullable column:

```ruby
add_column :daily_exercises, :regenerating_since, :datetime
```

Named to match the existing `daily_responses.reviewing_since`, which solves the
identical problem for reviews and whose claim/stale-window pattern this design
follows deliberately rather than inventing a second idiom.

No index: the column is only ever read from a row already loaded by the
`(user_id, date)` unique index, and never appears alone in a `WHERE` outside the
claim `UPDATE`, which is scoped by that same index.

Existing rows have `NULL`, which reads as "not regenerating", so no historical
row changes behavior.

```ruby
DailyExercisesController::REGENERATION_STALE_AFTER = 6.minutes
```

This must exceed `AiService::GENERATION_READ_TIMEOUT` plus job pickup latency,
or a still-running job looks abandoned and a second one can be enqueued on top
of it. A spec asserts that relationship so the two constants cannot drift apart.

### Claiming

`#regenerate` no longer touches a provider. It claims the row atomically:

```ruby
claimed = current_user.daily_exercises.for_date
  .where(regenerated_at: nil)
  .where("regenerating_since IS NULL OR regenerating_since < ?", REGENERATION_STALE_AFTER.ago)
  .update_all(regenerating_since: Time.current) == 1
```

A single `UPDATE` serves three purposes at once: the once-per-day gate
(`regenerated_at IS NULL`), the double-submit guard (a second click finds a
fresh claim and matches zero rows), and stale-claim recovery (a claim older than
the window is reclaimable). When the claim fails, the action redirects with the
existing "already generated" alert; when it succeeds it enqueues
`RegenerateExerciseJob` and redirects.

### RegenerateExerciseJob

A new job rather than a branch inside `GenerateDailyExercisesJob`. The cron
batch is load-bearing infrastructure, and its `generate_now` is explicitly
skip-if-exists — the exact opposite of regenerate's contract.

```
perform(user_id:)
  User.active.find_by(id: user_id)              # anonymized users are skipped
  Time.use_zone(user.effective_time_zone) do    # "today" resolves in the user's zone
    exercise = user.daily_exercises.for_date.first
    return unless exercise&.regenerating_since   # claim vanished — nothing to do
    problem_set = AiService.for(user).generate_exercise(user, language: exercise.language)
    transaction do
      exercise.daily_response&.destroy
      exercise.update!(problem_set:, generated_at: now, regenerated_at: now,
                       regenerating_since: nil)
    end
  end
```

Because it runs on the worker, `generate_exercise` is called without
`blocking:`, so it gets `GENERATION_READ_TIMEOUT`.

On failure it rescues the `AiService` hierarchy exactly as
`GenerateDailyExercisesJob` does, mapping to the same user-facing messages, and
**does not re-raise** — a failed background generation must never surface as a
user-facing crash. It then:

- clears `regenerating_since`
- leaves `regenerated_at` **nil**, so the user keeps their daily regenerate
- leaves `problem_set` **untouched**, so today's set survives
- persists `last_generation_error` / `last_generation_error_date`

An unexpected (non-`AiService`) exception leaves the claim set. That is what the
stale window recovers: the failure mode is a delayed retry, not a permanent
spinner.

### Reporting completion

`GET /dashboard/status` gains a pending branch, ordered before the existing
`ready` check so an in-flight regenerate isn't reported complete:

```
regenerating (claim present and fresh)   → pending
today's error present                    → failed
exercise exists                          → ready
```

`DashboardController#show` renders `dashboard/_generating` when the claim is
present and fresh, so the spinner and its poller are reused unchanged.

### Reporting failure

`#show` sets `@regeneration_failed` when an exercise exists *and*
`last_generation_error_date` is today; `_exercise` renders a banner above the
problem set. The existing error columns are reused — a later successful
generation already clears them — and the old set renders normally underneath.

### Polling window

The poller currently gives up after `40 × 3s = 120s`, which is already shorter
than the 300s the job may legitimately take. Derive it instead so it cannot
drift from the budget it covers:

```
MAX_ATTEMPTS = (AiService::GENERATION_READ_TIMEOUT + 90) / 3   # 130 attempts ≈ 390s
```

The partial's "usually takes about 10 seconds" copy is stale and is corrected
in the same change.

## Testing

Every item below is new behavior and needs coverage.

**Request (`spec/requests/daily_exercises_spec.rb`)**
- enqueues `RegenerateExerciseJob` and makes no inline provider call
- sets `regenerating_since`
- a second POST while claimed does not enqueue twice
- a claim older than `REGENERATION_STALE_AFTER` is reclaimable
- `regenerated_at` present still blocks with the existing alert

**Job (`spec/jobs/regenerate_exercise_job_spec.rb`)**
- success: `problem_set` replaced, `regenerated_at` set, claim cleared, existing
  `DailyResponse` destroyed
- failure: `problem_set` unchanged, `regenerated_at` still nil, claim cleared,
  message persisted, no exception escapes
- resolves "today" in the user's timezone
- skips an anonymized user

**Status / view**
- `pending` while claimed, `ready` once cleared
- spinner rendered while claimed
- failure banner rendered with the old set still present

**Invariants**
- `REGENERATION_STALE_AFTER > AiService::GENERATION_READ_TIMEOUT`
- polling window exceeds `AiService::GENERATION_READ_TIMEOUT`

No system spec: `FakeService` returns instantly, so the spinner is not reliably
observable in a browser test.

## Open question

Once `#regenerate` is asynchronous, `SYNC_GENERATION_READ_TIMEOUT` has no
caller. This design keeps the constant and its `blocking:` parameter, since they
document a real constraint for any future synchronous caller. If review prefers,
both can be deleted and reintroduced when actually needed.
