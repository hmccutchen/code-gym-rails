# Feedback UI, Teaching Notes, Concept Tagging

## Context

Three related features that deepen Code Gym's personalization loop, built in
this order (each independently shippable):

1. **Feedback submission UI** — surface the existing rating/feedback endpoint
   properly in the dashboard flow
2. **Teaching notes** — a per-problem hint, revealed on demand after the user
   has attempted an answer
3. **Concept tagging** — a fixed-vocabulary concept per problem, stored per
   response, feeding the daily generation prompt

Decisions made during brainstorming:
- Feedback is available **after submission** and becomes the prominent next
  step **after the AI review** (not strictly gated on the review — users who
  skip the review can still rate, maximizing rating data).
- Concept tags come from a **fixed vocabulary** (Ruby constant, embedded in
  the generation prompt); off-list tags normalize to `"other"` at parse time.

## Corrected premise (found during exploration)

`app/views/dashboard/show.html.erb:138-150` **already contains** a feedback
widget (three rating buttons + optional text) wired to
`ResponsesController#feedback`. Feature 1 is a re-gate and polish of that
widget, not a new build.

Adjacent bug folded into feature 1: the AI-review renderer
(`show.html.erb:159`) reads `feedback["summary"]`, but
`ClaudeService#review_response` returns `rating / correct / missed /
better_questions / next_step / improved_code` — there is no `summary` key, so
reviews currently render as empty blocks. Since feature 1's flow is
"read your review, then rate," the renderer must be fixed to the real keys.

## 1. Feedback submission UI

**Files:** `app/views/dashboard/show.html.erb` (only)

No controller, model, or route changes — `ResponsesController#feedback` and
the `rating`/`feedback_text` columns are used as-is.

Changes:
- **Quiet state (submitted, not yet reviewed):** the existing widget renders
  below the submitted badge in a visually muted style (small text, ghost
  buttons) — present but not the page's focus; the "Get Claude review →"
  button remains the primary action.
- **Prominent state (reviewed):** the widget renders *below* the review
  section as a highlighted card titled "How was today's difficulty?" — the
  clear next step after reading the review. Same form, same endpoint.
- The widget renders in exactly one place per page state (an `if
  @response.reviewed?` branch chooses position/styling), so there are never
  two feedback forms in the DOM.
- **Review renderer fix:** each review block shows the section's `rating` as
  a badge, then `correct`, `missed`, `better_questions`, `next_step` as
  labeled short paragraphs, and `improved_code` in a snippet block when
  present. Guard every key with `.presence` — older stored reviews may have
  different shapes.

## 2. Teaching notes

**Files:** `app/services/claude_service.rb`, `app/views/dashboard/show.html.erb`

Changes:
- `EXERCISE_SCHEMA` gains a `teaching_note` string per section (all three of
  `code_review`, `pattern`, `challenge`): "one or two sentences pointing
  toward the key insight — never the full answer."
- The generation prompt (`build_exercise_prompt`) gets one instruction line:
  teaching notes must hint at *how to think about* the problem, not what the
  answer is.
- Dashboard: each section renders a collapsed `<details class="hint">`
  ("Need a nudge?") **only when** `section["teaching_note"].present?` — old
  exercises without the field render exactly as today. No backfill, no
  regeneration.
- **Reveal gating:** before submission, the toggle is disabled (CSS
  `pointer-events` + visual state) until that section's textarea passes the
  existing >10-character threshold — the same heuristic the progress bar
  uses, enforced in the existing inline `<script>`. After submission it is
  always openable.
- Accepted trade-off: the note text is present in the DOM before reveal; a
  dev-tools peek is possible. These are hints, not exams.

## 3. Concept tagging

**Files:** `app/services/claude_service.rb`, `app/controllers/responses_controller.rb`,
`app/models/user.rb`, plus **one migration** (see below)

Vocabulary — a frozen constant on `ClaudeService`:

```ruby
CONCEPTS = %w[
  n_plus_one transaction_safety memoization service_objects scope_chaining
  idempotency authorization background_jobs caching validations
  callbacks_vs_service query_objects policy_objects indexing concurrency
  error_handling
].freeze
```

Changes:
- `EXERCISE_SCHEMA` gains a `concept` string per section; the generation
  prompt embeds the vocabulary and instructs Claude to choose exactly one
  concept per section from the list.
- `parse_json_response` output for exercises passes through a normalizer:
  any section `concept` not in `CONCEPTS` becomes `"other"` (nil stays nil
  for old shapes).
- **Migration required (flagging per constraints):** everything else in this
  spec fits inside existing jsonb, but storing tags per response needs a new
  column — `add_column :daily_responses, :concept_tags, :jsonb, default: {}`.
  Denormalizing onto `DailyResponse` keeps per-user concept history a plain
  column query; the alternative (joining `daily_exercises` and digging
  through `problem_set` with jsonb path operators) needs no migration but
  makes every aggregation query gnarly. Copying at answer time also
  preserves history if a problem_set is ever regenerated.
- `ResponsesController#create` copies the tags when saving answers:
  `concept_tags: { "code_review" => ..., "pattern" => ..., "challenge" => ... }`
  read from the exercise's `problem_set` (nil-safe for old exercises).

## 4. Personalization loop

**Files:** `app/models/user.rb`, `app/services/claude_service.rb`

Changes:
- `User#recent_performance` adds a `concepts` key to each session hash — the
  response's `concept_tags` map (empty hash for old rows).
- `build_exercise_prompt` history lines become e.g.
  `2026-07-08: 2/3 answered | too hard | concepts: n_plus_one, memoization, service_objects`
  (concepts omitted when empty).
- Prompt instructions gain an explicit mastery-tracking loop: for any
  concept whose most recent rating was "too_hard", that concept must be
  reintroduced in the next problem set — varying the code example and
  framing so it isn't a repeat of the same snippet, but keeping the same
  underlying concept — and continue reintroducing it on each subsequent
  generation until the user rates that concept "right_level" or "too_easy".
  Treat that rating as the mastery signal that ends the reinforcement loop
  for that concept. Concepts most recently rated "too_easy" should not
  repeat within the same week. Concepts most recently rated "right_level"
  have no special weighting. (The goal is persistent reinforcement until a
  clear signal the user has moved past the struggle — not stylistic
  variation.)
- Derivation note for implementers: ratings are stored per response (per
  day), not per concept — a concept's "most recent rating" means the
  `rating` of the most recent session whose `concept_tags` include that
  concept. This derivation lives in the history the prompt renders, so the
  model can apply the rule directly.

## Compatibility

- Old `problem_set` rows (no `teaching_note`, no `concept`) render and
  personalize exactly as today — `.presence`/nil guards at every read site.
- Old `daily_responses` rows get `concept_tags` `{}` via the column default;
  `recent_performance` treats missing/empty maps as "no concept data".
- No backfill and no regeneration of existing exercises.

## Testing

- Request specs: feedback action round-trip (rating + text persist);
  `#create` copies `concept_tags` from the exercise, `{}` when the exercise
  predates tagging.
- Model specs: `recent_performance` includes `concepts` per session, empty
  for untagged history.
- Service specs: `EXERCISE_SCHEMA` includes `teaching_note` and `concept`
  per section; the prompt embeds the `CONCEPTS` vocabulary; the normalizer
  maps off-list concepts to `"other"`.
- View behavior (gating, reveal states) is exercised at the request-spec
  level where practical (presence/absence of the hint markup and the
  feedback card per state), not via a JS test framework — the repo has none
  and this spec doesn't introduce one.

## Build order

1. Feedback UI re-gate + review-renderer fix (unlocks real rating data)
2. Teaching notes (prompt + schema + reveal UI)
3. Concept tagging (vocabulary + migration + copy-on-create + prompt loop)

## Out of scope

- Magic-link auth flow, Resend/SMTP setup, and the interim `/test_login`
  route — all untouched.
- UI for editing `skill_level` / `focus_areas` (separate future feature).
- Backfilling tags or teaching notes onto existing exercises.
