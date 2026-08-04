# FakeService + System Tests — Design

## Why

Every AI-generation and review code path is currently only reachable in tests
via request/model/service specs that stub HTTP at the Faraday layer, or not
exercised end-to-end at all. There is no automated coverage of the actual
browser-side behavior this app leans on most — the inline JS that gates the
Submit button on a rating, autosaves answers, and drives the review
loading-state/redirect — despite that behavior having a documented history of
being verified manually in Chrome. This adds a deterministic, zero-cost
third `AiService` provider for tests, and a small system-test suite that
drives it through a real browser.

## Part 1 — FakeService

### Interface

`FakeService < AiService`, overriding only the two methods every subclass
already implements:

- `#build_connection` — no-op (`nil`); never invoked, since `#call` never
  makes an HTTP request.
- `#call(system:, prompt:)` — returns `{ text:, input_tokens: 0,
  output_tokens: 0 }` with canned, deterministic `text`.

Every other `AiService` method (`generate_exercise`, `review_response`,
`generate_concept_reference`, `explain_differently`, `answer_follow_up`) is
inherited unmodified. This means `DailyPlan`, `log_usage`,
`normalize_concepts`, `log_retention`, `shuffle_parsons_blocks!`, and
`override_parsons_rating!` all run for real against the fake's output —
FakeService only ever fakes the network hop, so tests exercise the same
control flow a real provider triggers.

### Dispatch inside `#call`

Each `AiService` caller passes a distinct, literal `system:` string.
`#call` pattern-matches on that string to decide which canned response to
return:

| Caller | `system:` match | Response shape |
|---|---|---|
| `generate_exercise` | `"generating personalized daily exercise sets"` | One canned JSON object with **all six** section keys populated at once: `code_review`, `pattern`, `challenge`, `architecture`, `security_review`, `parsons_problem`. Valid regardless of which third `DailyPlan` picked — `DailyExercise#third_key` resolves by precedence over whatever keys are present, and `normalize_concepts` only touches keys that exist. |
| `review_response` | `"giving direct, specific feedback"` | The exercise's `third_key` is extracted from the prompt's literal closing line (`Return JSON with keys: "code_review", "pattern", "#{third_key}"`) via regex, then a review JSON keyed to exactly `code_review`, `pattern`, and that third is returned. |
| `generate_concept_reference` | `"writing a concise, durable reference"` | Canned JSON covering every `DailyResponse::CONCEPT_REFERENCE_FIELDS` — that method raises if any field is blank. |
| `explain_differently` | `"re-explaining one point"` | Canned plain-prose string (no JSON parsing on this path). |
| `answer_follow_up` | `"answering a follow-up question"` | Canned plain-prose string. |

Canned exercise-JSON content is written to be realistic enough to render
correctly through every `ExerciseSection` kind's view partial: valid
`concept` values from the closed vocabularies, non-empty `teaching_note`,
`glossary`, `snippet`/`question` fields, and (for `parsons_problem`) a
`blocks` array in solvable order.

### Wiring

- `AiService.for(user)` gains one added branch: `when "fake" then
  FakeService.new(user.api_key)`.
- `User#provider` inclusion validation gains `"fake"`: `%w[anthropic gemini
  fake]`.
- No migration: `provider` is a plain `string` column with no DB-level
  constraint.
- `ApiKeysController::PROVIDER_PATTERNS` is untouched. No key format maps to
  `"fake"`, so it stays structurally unreachable from the real
  key-entry/settings UI — nothing further to guard.

### Test user

A `spec/support` helper, `create_fake_provider_user`, mirrors the existing
`AuthHelpers#create_user_with_key` but sets `provider: "fake"` and a fixed
dummy `api_key` (never sent anywhere, but present since the column expects a
value once a provider is set). Available to both request specs and the new
system specs. This is test-only infrastructure, not demo content, so it does
not go through `PreviewSeed`/`db/seeds.rb`.

## Part 2 — System tests

### Setup

- New, separate Gemfile group (not merged into the existing `group
  :development, :test`):

  ```ruby
  group :test do
    gem "capybara"
    gem "capybara-playwright-driver"
  end
  ```

  This keeps both gems out of development as well as production.
- `spec/support/system_test_helper.rb`: `driven_by :playwright` (headless)
  for `type: :system` specs, per the gem's standard Capybara driver
  registration.
- A system-test login helper visits the verify-token URL through a real page
  load (`visit verify_auth_path(token: ...)`) rather than the request-spec
  helper's `get`, since Capybara drives an actual browser.

### Specs (`spec/system/`)

Three specs, each using the fake-provider test user exclusively — no system
spec ever touches a real API key:

1. **Dashboard generation** — log in, land on the dashboard with no exercise
   yet generated, confirm on-demand generation runs and today's exercise
   renders (all three visible sections present).
2. **Rating-gated submit** — fill in one section's answer, rate all three
   sections via the rating buttons, confirm the Submit button transitions
   from disabled to enabled live (proving the inline JS, not a stub, is
   driving it), submit, confirm the page shows the submitted/read-only
   state.
3. **Review request** — from a submitted day, click "Request review",
   confirm the loading-state script fires (button disables/relabels) and the
   page ends up redirected to `/history` anchored at that day with the AI
   review content visible.

### Non-goals

- No conversion of existing request/model/service/job specs to system
  specs — this is additive coverage for genuinely browser-dependent
  behavior (real page loads, live inline JS), not a replacement for the
  existing suite.
- No coverage added here for `generate_concept_reference`,
  `explain_differently`, or `answer_follow_up` at the system-test level;
  FakeService supports them (so a browser flow that happens to touch them
  won't error), but no dedicated system spec exercises them directly.
