# Regenerate Button + Multi-Provider (Anthropic/Gemini) Support

## Context

Two related but independent features, built in this order:

1. **Regenerate button** — let a user manually re-run today's exercise
   generation (separate from the 8am cron), replacing the existing
   `DailyExercise` row's contents rather than creating a new one, capped at
   once per day, with a confirmation that scales to how much the user stands
   to lose.
2. **Multi-provider support** — let users bring a Google Gemini key
   (`AIza...`) as an alternative to an Anthropic key (`sk-ant-...`), detected
   automatically from the key's prefix at save time, with the AI-calling
   logic refactored behind a shared interface so `GenerateDailyExercisesJob`,
   `ResponsesController#review`, and the new regenerate action don't need to
   know which provider a given user is on.

Both fit inside existing tables plus small additive migrations — no changes
to magic-link auth, Resend/SMTP, `/test_login`, concept tagging, teaching
notes, or the feedback UI.

## 1. Regenerate button

**Files:** `db/migrate/*_add_regenerated_at_to_daily_exercises.rb`,
`app/models/daily_exercise.rb`, `app/controllers/daily_exercises_controller.rb`
(new), `config/routes.rb`, `app/views/dashboard/show.html.erb`

### Data model

```ruby
add_column :daily_exercises, :regenerated_at, :datetime
```

No default — `nil` means "not yet manually regenerated today." Because
`DailyExercise` is unique per `user_id` + `date` (existing constraint), this
column resets naturally every day: today's regeneration cap lives entirely on
today's row, and tomorrow's cron-generated row starts fresh with `nil`.

### Controller flow

New `DailyExercisesController#regenerate`, `POST /regenerate`:

```ruby
class DailyExercisesController < ApplicationController
  def regenerate
    exercise = current_user.daily_exercises.for_date.first
    return redirect_to root_path, alert: "No exercise set to regenerate yet." unless exercise

    if exercise.regenerated_at.present?
      return redirect_to root_path, alert: "You've already generated a new set today."
    end

    exercise.daily_response&.destroy

    problem_set = AiService.for(current_user).generate_exercise(current_user)
    exercise.update!(
      problem_set:     problem_set,
      generated_at:    Time.current,
      regenerated_at:  Time.current
    )

    redirect_to root_path, notice: "New set generated!"
  rescue AiService::Error => e
    redirect_to root_path, alert: "Couldn't generate a new set: #{e.message}"
  end
end
```

Route (grouped with the other top-level actions, same style as `history` and
`setup`):

```ruby
post "regenerate", to: "daily_exercises#regenerate"
```

Destroying `exercise.daily_response` first means the `problem_set` update and
the wipe of the user's answers/rating/review happen as one conceptual unit —
if `update!` raises, the user has already lost their old answers but not
gotten a new set; this is an accepted edge case (matches how other
Claude-call failures already surface as a flash alert with no compensating
transaction elsewhere in the app).

### Dashboard UI

Rendered near the top of the exercise content, only when `@exercise.present?`
(never during the `@generating` state, never when there's no exercise yet):

```erb
<% if @exercise.regenerated_at.present? %>
  <p class="hint">You've already generated a new set today.</p>
<% else %>
  <% confirm_msg = @response&.answers&.values&.any?(&:present?) || @response&.submitted? ?
       "This will replace today's problems and erase your answers so far. This can't be undone. Continue?" :
       "Generate a new set for today?" %>
  <%= button_to "Generate new set", regenerate_path, method: :post,
        class: "btn btn-ghost btn-sm", data: { turbo_confirm: confirm_msg } %>
<% end %>
```

`data-turbo-confirm` is Turbo's built-in confirm dialog (already loaded via
`@hotwired/turbo-rails`) — no new JS needed, consistent with the rest of the
dashboard using plain inline `<script>` rather than Stimulus controllers for
one-off behavior.

### Compatibility

- Existing `DailyExercise` rows get `regenerated_at: nil` via the plain
  `add_column` (no backfill needed — absence of a value is the correct
  "not regenerated" state for historical rows too).
- `History` page and stored `DailyResponse` records for *past* days are
  untouched; this feature only ever touches today's row.

## 2. Multi-provider support (Anthropic + Gemini)

**Files:** `db/migrate/*_add_provider_to_users.rb`,
`db/migrate/*_backfill_user_provider.rb`, `app/models/user.rb`,
`app/controllers/api_keys_controller.rb`, `app/services/ai_service.rb` (new),
`app/services/claude_service.rb` (refactored), `app/services/gemini_service.rb`
(new), `app/jobs/generate_daily_exercises_job.rb`,
`app/controllers/responses_controller.rb`,
`app/controllers/daily_exercises_controller.rb`

### Data model

```ruby
add_column :users, :provider, :string
```

No default; nil is valid pre-`/setup`. Validated on `User`:

```ruby
validates :provider, inclusion: { in: %w[anthropic gemini] }, allow_nil: true
```

**Backfill migration** (separate data migration, run once after the column
migration): every existing user already has an Anthropic key under the old
`sk-ant-`-only validation, but we don't assume that — we derive it the same
way the controller will going forward, in case any stray key slipped through:

```ruby
class BackfillUserProvider < ActiveRecord::Migration[8.0]
  def up
    User.where.not(api_key: nil).find_each do |user|
      key = user.api_key # decrypts transparently via `encrypts :api_key`
      provider =
        case key
        when /\Ask-ant-/ then "anthropic"
        when /\AAIza/    then "gemini"
        end

      if provider
        user.update_column(:provider, provider)
      else
        Rails.logger.warn("BackfillUserProvider: unrecognized key format for user #{user.id}")
      end
    end
  end

  def down
    # no-op; provider column removal handled by reverting the schema migration
  end
end
```

### Key detection (`ApiKeysController`)

```ruby
def update
  key = params[:api_key].to_s.strip
  provider =
    case key
    when /\Ask-ant-/ then "anthropic"
    when /\AAIza/    then "gemini"
    end

  unless provider
    flash.now[:alert] = "We don't recognize this key format — currently supporting Anthropic and Gemini keys."
    render :edit, status: :unprocessable_entity
    return
  end

  current_user.update!(api_key: key, provider: provider)
  redirect_to root_path, notice: "API key saved. You're all set!"
end
```

The `/setup` view is unchanged: one password field, generic placeholder text
("Paste your Anthropic or Gemini API key"), no provider dropdown. The user
never has to declare which provider they're on.

### Service architecture

`app/services/ai_service.rb` — abstract base holding everything
provider-agnostic:

- `AiService::Error` — shared rescuable error class (replaces
  `ClaudeService::Error` at all call sites).
- `CONCEPTS`, `RATING_LABELS`, `EXERCISE_SCHEMA` constants (moved as-is from
  `ClaudeService`).
- `generate_exercise(user)` / `review_response(user, exercise, daily_response)`
  — public methods, unchanged behavior/signatures from today's
  `ClaudeService`, built on top of a private template method `#call(system:,
  messages:)` that subclasses implement.
- `build_system_prompt`, `build_exercise_prompt`, `build_review_prompt`,
  `normalize_concepts`, `log_usage`, `parse_json_response` — moved as-is
  (provider-agnostic: they only shape text and read `usage`/parsed JSON, not
  the raw HTTP envelope).
- `AiService.for(user)` class method — the dispatch factory:

  ```ruby
  def self.for(user)
    case user.provider
    when "anthropic" then ClaudeService.new(user.api_key)
    when "gemini"    then GeminiService.new(user.api_key)
    else
      raise Error, "User #{user.id} has no recognized AI provider configured"
    end
  end
  ```

`app/services/claude_service.rb` — shrinks to just the Anthropic-specific
parts: `MODEL`, `API_URL`, `build_connection` (Faraday + `x-api-key` /
`anthropic-version` headers), and `#call` (posts
`{model, max_tokens, system, messages}`, returns the raw parsed response for
the base class's `resp.dig("content", 0, "text")` / `resp["usage"]` reads —
**exact split of "what `#call` returns" vs. "what the base class reads" is an
implementation detail**, as long as the Anthropic-shaped envelope is fully
contained in `ClaudeService`).

`app/services/gemini_service.rb` — new class, same shape: `MODEL =
"gemini-3.5-flash"`, its own `API_URL`, `build_connection`, and `#call`
adapted to Gemini's request/response shape.

Call sites switch from `ClaudeService.new(user.api_key)` to
`AiService.for(user)`, and from `rescue ClaudeService::Error` to `rescue
AiService::Error`:

- `GenerateDailyExercisesJob#generate_for`
- `ResponsesController#review`
- `DailyExercisesController#regenerate` (new, from part 1 above)

### Open question — Gemini request/response mapping

This spec fixes the **class boundary** (`GeminiService` owns 100% of
Gemini's request/response shape; nothing Gemini-specific leaks into
`AiService`) but deliberately does **not** lock the exact mapping, since
Anthropic's and Gemini's APIs differ in ways that need to be checked against
current provider docs at implementation time, not guessed here:

- **System prompt convention** — Anthropic takes a top-level `system` string;
  Gemini uses a separate `systemInstruction` object in the request body.
- **JSON-mode/schema enforcement** — Anthropic relies on prompt instructions
  only (`EXERCISE_SCHEMA` is embedded as text and Claude is asked to "return
  ONLY valid JSON"). Gemini has native structured-output support
  (`generationConfig.responseMimeType: "application/json"` and optionally
  `responseSchema`) that may be worth using instead of prompt-only
  enforcement — but that's an implementation choice, not assumed here.
  `parse_json_response`'s fence-stripping fallback in the base class still
  applies either way, so behavior is safe even if Gemini occasionally wraps
  output in markdown fences.
- **Response envelope** — Anthropic: `content[0].text` /
  `usage.input_tokens` / `usage.output_tokens`. Gemini:
  `candidates[0].content.parts[0].text` and a differently-shaped
  `usageMetadata` (e.g. `promptTokenCount` / `candidatesTokenCount`) — exact
  field names to be confirmed against Gemini's current API reference during
  implementation.
- **Retry-worthy status codes** — `ClaudeService` retries on Anthropic's
  `529` (overloaded). Gemini's equivalent (if any) should be looked up
  separately rather than assumed to be the same code.

### Compatibility

- Existing users get `provider` backfilled by the data migration; the
  `AiService.for` factory raises `AiService::Error` (caught by existing
  rescues, surfaced as a flash alert) in the unexpected case where `provider`
  is still nil — no silent fallback/guessing.
- `ApiUsage` logging (`purpose`, `tokens_in`, `tokens_out`) is unchanged;
  provider is inferable from the user at the time, no new column added since
  nothing in this spec's scope reads usage broken out by provider.

## Testing

- **Request spec** — `DailyExercisesController#regenerate`: happy path
  (updates `problem_set`/`regenerated_at`, destroys prior `daily_response`),
  cap-exceeded path (second call same day is blocked with an alert, row
  unchanged), missing-exercise path (404/redirect with alert).
- **View/request-level spec** — regenerate button absent when no exercise,
  present with light-confirm text when no answers yet, present with
  strong-warning text when answers exist or already submitted, replaced with
  the "already regenerated" message once `regenerated_at` is set.
- **Request spec** — `ApiKeysController#update`: `sk-ant-...` → `provider:
  "anthropic"`; `AIza...` → `provider: "gemini"`; unrecognized prefix →
  inline error, no update, `provider` left as-is.
- **Service specs**:
  - `AiService` (via a lightweight test double subclass implementing `#call`)
    — JSON fence-stripping, concept normalization to `"other"`, prompt
    content includes the concept vocabulary and mastery-loop instructions
    (already-covered `ClaudeService` behavior, now tested once at the base
    class level instead of duplicated).
  - `ClaudeService` — only its `#call` request shape (Faraday double,
    correct headers/body) and response parsing (`content[0].text`,
    `usage`).
  - `GeminiService` — same shape of spec, once the request/response mapping
    is implemented; not written until that open question is resolved.
  - `AiService.for` — dispatches to `ClaudeService`/`GeminiService` based on
    `user.provider`; raises `AiService::Error` for nil/unrecognized.
- **Migration/data spec or one-off script check** — backfill migration sets
  `provider` correctly for a seeded Anthropic-shaped key.

## Build order

1. `AiService` base class extraction (pure refactor of existing
   `ClaudeService` — no behavior change, existing specs must still pass).
2. `provider` column + `ApiKeysController` detection + backfill migration.
3. `GeminiService` (blocked on resolving the open question above).
4. `AiService.for` factory + call-site swaps
   (job/`ResponsesController#review`).
5. Regenerate button (`regenerated_at` column, `DailyExercisesController`,
   dashboard UI) — independent of steps 1–4, can ship first or in parallel.

## Out of scope

- Magic-link auth, Resend/SMTP setup, `/test_login` — untouched.
- Concept tagging, teaching notes, feedback UI — untouched.
- A provider dropdown or any UI acknowledging which provider a user is on
  (beyond the inline rejection error) — auto-detection stays invisible.
- Per-provider `ApiUsage` breakdown/reporting.
- Rate-limit/retry-code parity between providers — flagged above, not solved
  here.
