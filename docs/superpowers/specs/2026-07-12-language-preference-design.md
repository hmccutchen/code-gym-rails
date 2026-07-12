# Language Preference for Generated Problems

## Problem

All generated problems currently assume Ruby/Rails. Engineers working primarily
in JavaScript/React get no value from Code Gym. We need a per-user preference
for which language(s) their daily exercise sets are generated in, without
disrupting the existing (unchanged) Ruby/Rails default or any of the
auth/email/feedback/multi-provider work already in flight.

## Goals

- Per-user `language` preference: `"ruby_rails"` (default, current behavior),
  `"javascript"`, or `"mixed"`.
- `"ruby_rails"` and `"javascript"` pin that language explicitly in the
  generation prompt — no ambiguity.
- `"mixed"` keeps each day's full set (code_review, pattern, challenge) in ONE
  language, alternating across days.
- Extensible: adding a future 4th language should not require another
  migration, just a code change.
- Reuse the existing `/setup` settings page rather than building a new
  surface.

## Non-goals / explicitly out of scope

- No changes to magic-link auth, Resend/SMTP, `/test_login`, feedback UI,
  regenerate-button/multi-provider work, or the email/history-page spec.
- No dynamic/AI-extensible concept vocabulary. The concept list stays closed
  (see "Future ideas" below) — this keeps concept-history aggregation
  (`user.recent_performance`) consistent, per the existing design comment in
  `ai_service.rb`.

## Schema changes (2 migrations)

### 1. `users.language`

```ruby
add_column :users, :language, :string, null: false, default: "ruby_rails"
```

Validated in `User`:

```ruby
LANGUAGES = %w[ruby_rails javascript mixed].freeze
validates :language, inclusion: { in: LANGUAGES }
```

`LANGUAGES` is a plain Ruby array, not a Postgres/Rails `enum` type — adding a
future language is a one-line constant change plus corresponding prompt/
vocabulary support, no migration.

### 2. `daily_exercises.language`

```ruby
add_column :daily_exercises, :language, :string, null: false, default: "ruby_rails"
```

Records which language a specific day's set was **actually generated in**.
This is the mechanism that makes "mixed" alternation and single-day
consistency work:

- Set once, when the `DailyExercise` row is created.
- `DailyExercisesController#regenerate` reads the existing row's `language`
  and passes it back into generation — it never recomputes or flips
  alternation. This guarantees a single calendar day is never split across
  languages, even across regenerations.
- Existing rows backfill to `"ruby_rails"` via the column default, matching
  current (unchanged) behavior for all past exercises.

## Alternation logic for "mixed"

New method, `User#language_for_today`:

```ruby
def language_for_today
  return language unless language == "mixed"

  last = daily_exercises.where.not(date: Date.current).order(date: :desc).first
  return "ruby_rails" unless last

  last.language == "ruby_rails" ? "javascript" : "ruby_rails"
end
```

Rule stated explicitly: **look at the most recent prior `DailyExercise`
(excluding today) and flip its language. If none exists yet (first-ever set
for this user), default to `"ruby_rails"`.**

This is called exactly once, by `GenerateDailyExercisesJob#generate_for`, when
first creating today's row. It is intentionally NOT called by
`DailyExercisesController#regenerate`, which instead reuses
`exercise.language` from the row being regenerated.

## Concept vocabulary

`AiService::CONCEPTS` is renamed `RAILS_CONCEPTS` (kept as the same list,
same values, just a clearer name now that there's a second vocabulary). A new
parallel list is added:

```ruby
RAILS_CONCEPTS = %w[
  n_plus_one transaction_safety memoization service_objects scope_chaining
  idempotency authorization background_jobs caching validations
  callbacks_vs_service query_objects policy_objects indexing concurrency
  error_handling
].freeze

JS_CONCEPTS = %w[
  callback_hell promise_chaining closures prototype_chain event_loop_blocking
  this_binding array_mutation_pitfalls debouncing_throttling closures_in_loops
  memory_leaks_listeners hooks_dependencies component_re_renders state_lifting
  controlled_vs_uncontrolled
].freeze
```

**Ecosystem assumption for `"javascript"`**: vanilla JS as the primary focus,
with React concepts (hooks, re-renders, controlled/uncontrolled components,
state lifting) mixed in — no Node/Express backend track for now.

Since each day under `"mixed"` is single-language (never split within a day),
each response's `concept_tags` just uses whichever vocabulary matches that
day's `language` — no per-section mixing logic is needed. `normalize_concepts`
picks the correct list to validate against based on the day's language.

## Prompt construction changes (`app/services/ai_service.rb`)

- `generate_exercise(user)` computes `language = user.language_for_today`
  once, and threads it through to both prompt builders. The determined
  language is returned alongside the problem set so callers
  (`GenerateDailyExercisesJob`, `DailyExercisesController#regenerate`) can
  persist it on the `DailyExercise` row.
- `build_system_prompt(language)`: for `"ruby_rails"` keeps the current
  Rails-focused system prompt unchanged. For `"javascript"`, swaps in a
  JS/React-focused equivalent (senior JS/React coach; focus on closures,
  async/event-loop pitfalls, hooks, re-renders, prototypal inheritance,
  `this` binding).
- `build_exercise_prompt(user, language)`: concept vocabulary line uses
  `RAILS_CONCEPTS` or `JS_CONCEPTS` based on `language`. The schema
  description for the `snippet`/`code_example`/`starter_code` fields
  ("Ruby/Rails code, ~10-15 lines") becomes a language-driven label
  ("JavaScript/React code, ~10-15 lines") — no separate JSON schema needed.
  `teaching_note` instructions are already language-agnostic and need no
  change; the prompt's language-specific instructions only affect vocabulary
  and code-snippet framing, not phrasing that assumes Ruby idioms elsewhere.
- `normalize_concepts(problem_set, language)`: validates each section's
  `concept` against the vocabulary matching `language` instead of the single
  hardcoded `CONCEPTS` list.

## Settings UI (`/setup`)

No new controller or route. Add one `<select name="language">` to the
existing `app/views/api_keys/edit.html.erb` form, below the API key field:

- "Ruby / Rails (default)" → `ruby_rails`
- "JavaScript (vanilla + React)" → `javascript`
- "Mixed (alternates daily)" → `mixed`

`ApiKeysController#update` reads `params[:language]`; if present and valid
(`User::LANGUAGES.include?`), includes it in the same
`current_user.update!(api_key:, provider:, language:)` call used for the API
key. An invalid/blank value is silently ignored (falls back to the user's
current stored value) rather than blocking the API-key save, since language
preference is secondary to getting the API key saved.

## Testing plan

- `User` model spec: `language` inclusion validation; default value on new
  records; `language_for_today` — pinned values return themselves; `"mixed"`
  with no prior exercise defaults to `ruby_rails`; `"mixed"` with a prior
  `ruby_rails` exercise returns `javascript` and vice versa.
- `AiService` (or a shared example run against `ClaudeService`/
  `GeminiService`) spec: system/exercise prompts differ by language;
  `RAILS_CONCEPTS`/`JS_CONCEPTS` selection; `normalize_concepts` normalizes
  out-of-vocabulary concepts per language.
- `GenerateDailyExercisesJob` spec: persists the language returned by
  `generate_exercise` onto the new `DailyExercise.language` column.
- `DailyExercisesController#regenerate` spec: regenerating preserves the
  existing row's `language` (does not re-run alternation).
- `ApiKeysController#update` request spec: valid language value saves;
  invalid value ignored without blocking API key save.

## Future ideas (explicitly deferred)

- Allowing the AI to propose/add new concept tags over time instead of a
  fixed closed vocabulary. Deferred because it conflicts with the existing
  design intent of a closed vocabulary for clean concept-history aggregation,
  and needs its own normalization/review strategy to avoid tag sprawl. Not
  part of this feature.
