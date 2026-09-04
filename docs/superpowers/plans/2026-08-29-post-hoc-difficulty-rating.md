# Post-Hoc Difficulty Rating Implementation Plan

**Goal:** After a section is reviewed, show an objective difficulty rating for
that specific problem alongside its review — so a rough grade reads as "this
problem was legitimately hard" rather than as unexplained struggle. The rating
assesses the CONTENT (bug subtlety, reasoning steps, unstated context), never
the engineer, and must not become a second readout of their `ConceptMastery`
tier.

**Architecture:** A review-time, content-only assessment pass. `AiService`
gains `#assess_difficulty(user, exercise, sections:)` — a signature that takes
no `daily_response`, so it structurally cannot see answers, self-ratings, the
AI grade, tier, or mastery history. It builds its material from
`AiService#duck_section_context`, the existing single authority for "this
section as the engineer sees it," and runs as one extra thread inside the
existing `#review_sections` fan-out. The result is merged into
`ai_review[section]["difficulty"]` — an existing `jsonb` column, so there is
no migration.

**Tech Stack:** Ruby on Rails 8, RSpec, the existing `AiService` template-method
provider abstraction.

## Global Constraints

- **No migration, no new table, no schema change.** `daily_responses.ai_review`
  is already `jsonb`.
- **No change to `ConceptMastery`** — tiers, `record_review!`, `AI_RATING_RANK`,
  streaks, and retention scheduling are untouched. This is display-only.
- **No change to generation** — no prompt text, schema fragment, or `DailyPlan`
  logic changes. `spec/fixtures/prompt_snapshots/` must not rebaseline.
- The difficulty pass must never cost the engineer a paid review: any failure
  in it is swallowed and the note is simply absent.
- Full design rationale below is the deliverable the work was gated on; do not
  start Task 1 before it is committed.

---

## The design decision, resolved

Today a reviewed section shows two ratings, and both are judgments about the
person: the engineer's own self-rating (`DailyResponse::SELF_RATINGS`,
`too_easy`/`right_level`/`too_hard`) and the AI's grade of their answer
(`ai_review[section]["rating"]`, `beginner`/`developing`/`solid`/`strong`). So a
`developing` on a genuinely subtle n+1 reads exactly like a `developing` on a
gimme. This adds a third, orthogonal signal about the problem itself.

The constraint that decides the design: `ConceptMastery`'s tier was
deliberately kept invisible to the engineer. If this rating tracks tier, it
re-exposes that signal under a new name. A reduced-tier problem and a
full-difficulty retention check must both be gradeable as *either* difficulty.

### Rejected: generation-time self-assessment

The generation prompt is saturated with tier. Each reinforcement concept is
interpolated as `n_plus_one (reduced)`, and the instruction beside it reads
*"for any concept marked `(reduced)` … Ease the difficulty only: simpler
framing, a smaller scenario, more scaffolding …"*, while the retention block
reads *"Pitch these at FULL difficulty."*

Asking that same completion, in that same JSON object, "and how hard is this?"
is asking the model to grade the instruction it was just given. The output
would track tier almost by construction — which is the named risk, one step
removed rather than avoided.

Two secondary costs confirm it. The field would live in `problem_set`, making
pre-answer leakage a permanent audit obligation across every current and future
partial (the `planted_ambiguities` discipline). And it would rebaseline all 72
generation prompt snapshots.

### Rejected: folded into the existing per-section review JSON

Zero extra provider calls, and tier is genuinely absent from the review prompt.
But `AiService#build_review_day_context` hands every review thread the whole
day's context — **every section's answer and self-rating**. A difficulty rating
produced there can launder performance into difficulty: *you did badly,
therefore it was hard*. That is circular, carries no information, and
reintroduces a tier correlation through the back door, since tier is itself a
function of past performance. Only a prompt sentence could hold that line.

### Chosen: review-time, isolated content-only pass

`#assess_difficulty(user, exercise, sections:)` takes no `daily_response`. It
cannot see the answers, the self-ratings, the AI grade, the tier, the mastery
history, or the skill level, because none of them are passed to it. **The
guarantee is a method signature, not a prompt sentence.**

Its per-section material comes from `#duck_section_context` — a closed
enumeration of visible fields that already excludes `planted_ambiguities` and
withholds the solved parsons order. Reusing it rather than adding a per-kind
`.difficulty_context` keeps the section registry rule intact (adding a kind
stays "add a class") and means the two callers can never disagree about what
the engineer can see.

Running it as one more thread in the existing fan-out gives:

- **cost:** +1 provider call per *review attempt* — not per section;
- **latency:** zero added wall-clock, the fan-out is already threaded;
- **failure:** isolated — the grades still land, the note is absent;
- **retries:** a partial retry assesses only that attempt's missing sections.

It is also checkable after the fact: `ResponsesController#log_review_diagnostics`
already pairs `ai_rating` and `self_rating` per section, so production logs can
answer whether difficulty tracks content or merely echoes the grade.

### Scale

`DailyResponse::DIFFICULTY_LEVELS = %w[straightforward moderate demanding]`,
each rating carrying a one-sentence `reason` naming what makes it so.

Three levels, not four, and content-descriptive words rather than
person-descriptive ones: deliberately a different length *and* a different
vocabulary from the 4-level AI grade sitting inches away in the same review
block, so the two badges cannot be read as one axis.
`beginner/developing/solid/strong` is already overloaded — it is the AI grade
*and* `User#skill_level`. The `reason` is what keeps this context for reading
the grade rather than a standalone score.

---

## Leakage-prevention audit

**The structural claim:** `difficulty` never enters `problem_set`. It exists
only inside `ai_review`, which is `nil` until `ResponsesController#review`
writes it, and that action returns early unless `@response.submitted?`. No
pre-answer surface can reach the field even in principle — unlike
`planted_ambiguities`, which lives in `problem_set` and is kept off the page by
enumeration discipline alone.

Surfaces that can see a section pre-answer, all confirmed to read `problem_set`
and never `ai_review`:

| Surface | Reads `problem_set` | Reads `ai_review` |
|---|---|---|
| `responses/_sections`, `responses/_section` | yes (`problem_set[key]` verbatim) | no |
| `responses/bodies/*` (9 partials) | yes | no |
| `responses/answers/*` (3 partials) | yes | no |
| `dashboard/_teaching_hint` | yes | no |
| `AiService#duck_section_context` (pre-submission AI context) | yes | no |
| `AiService#without_answer_key` → difficulty-diagnostics log | yes | no |

Surfaces that do read `ai_review`, all post-review by construction:

- `shared/_ai_review` — reached only via `responses/_submission` (gated on
  `response.reviewed?`) and `history/index.html.erb` (gated on
  `daily_response.reviewed?`);
- `review_mailer/send_review.text.erb`;
- `DailyResponse#reviewed?` / `#fully_reviewed?` / `#section_reviewed?` /
  `#ai_rating_for`;
- `AiService#explain_differently` / `#answer_follow_up` — both post-review.

The audit runs in the other direction too, and that is the one this feature
turns on: the difficulty prompt must carry no tier and no performance. Enforced
by signature, pinned by spec in Task 2.

---

## Task 1: The vocabulary and its reader

**Files:**
- Modify: `app/models/daily_response.rb` (constants beside `SELF_RATINGS`;
  reader beside `#ai_rating_for`)
- Test: `spec/models/daily_response_spec.rb`

Add `DIFFICULTY_LEVELS` and `MAX_DIFFICULTY_REASON_LENGTH`, and a
`#difficulty_for(section)` that validates on read — the review path has no
`ProblemSetIngest` equivalent, so the reader is where a malformed level is
refused.

Do **not** add `"difficulty"` to `AI_REVIEW_FIELDS`: that map drives the
generic prose loop in both the view and the mailer, and this renders specially,
like `rating` and `improved_code`.

- [ ] Write the failing specs: nil when absent, nil for an off-vocabulary
      level, nil for a non-Hash, the hash when valid.
- [ ] Implement.
- [ ] `bundle exec rspec spec/models/daily_response_spec.rb`

---

## Task 2: The assessment pass

**Files:**
- Modify: `app/services/ai_service.rb`
- Test: `spec/services/ai_service_spec.rb`

- [ ] Extract the existing per-section thread body of `#review_sections` into a
      private `#grade_section` — mechanical, no behavior change, and it makes
      room under the 25-line guidance.
- [ ] Add the difficulty thread to `#review_sections`, started before the
      grading threads so both run concurrently; merge into `r[:review]` only
      where `r[:ok]`.
- [ ] `#assess_difficulty` rescues `AiService::Error` and returns `{}`.
- [ ] `#build_difficulty_prompt` interpolates the level names from
      `DailyResponse::DIFFICULTY_LEVELS` so prompt and validator cannot drift;
      only the per-level descriptions are prompt text.
- [ ] A distinctive system-prompt opening line (FakeService dispatches on it)
      and `purpose: "assess_difficulty"` for `ApiUsage`.
- [ ] `#usable_difficulty` — the boundary validator, placed beside
      `#override_parsons_section_rating!`, the existing precedent for
      normalizing review output in-service.
- [ ] Widen the doc comment on `#duck_section_context` to name its two callers.

**Specs — the leakage audit, made executable:**

- [ ] The difficulty prompt contains none of: the user's name, `skill_level`,
      `(reduced)`, `(standard)`, any answer text, any `section_ratings` value,
      or `planted_ambiguities`.
- [ ] It names exactly the levels in `DailyResponse::DIFFICULTY_LEVELS`.
- [ ] `#review_sections` merges difficulty into each successful section.
- [ ] A raised error in the difficulty pass leaves the grades intact.
- [ ] An off-vocabulary level is dropped, not persisted.

---

## Task 3: Display

**Files:**
- Modify: `app/views/shared/_ai_review.html.erb`, `config/locales/en.yml`,
  `app/views/layouts/application.html.erb`,
  `app/views/review_mailer/send_review.text.erb`

- [ ] Render the note immediately after the `<h4>` carrying the section name and
      AI grade badge, and before the calibration note — the difficulty is
      context for the grade above it.
- [ ] `review.difficulty_note` locale string, phrased so it can never read as a
      score about the engineer.
- [ ] A muted `.difficulty-note` rule beside `.calibration-note`. A sentence,
      not a badge.
- [ ] The same lines in the mailer — the email is the same review, and a second
      rendering that disagrees is worse than none.

---

## Task 4: Fakes and preview

**Files:**
- Modify: `app/services/fake_service.rb`, `app/services/preview_seed.rb`
- Test: `spec/services/fake_service_spec.rb`

- [ ] A `DIFFICULTY_ASSESSMENT` constant and a new `when` branch in
      `FakeService#call`. **Required, not optional:** the `else` branch raises
      on an unrecognized system prompt, so without this every system spec that
      reviews a day breaks. Unlike `REVIEW_SECTION`, the response must be keyed
      by the section names parsed out of the prompt.
- [ ] Canned difficulty in `PreviewSeed`'s reviews, varying the level across
      the seeded days so a reviewer sees the range.

---

## Task 5: The pre-submission non-leak regression

**Files:**
- Test: `spec/requests/dashboard_spec.rb`, `spec/requests/responses_spec.rb`

- [ ] Mirroring the `AH-SECRET-ONE` sentinel discipline in
      `spec/requests/section_rendering_characterization_spec.rb`: force-write an
      `ai_review` carrying a sentinel difficulty reason onto an **unsubmitted**
      response, request the dashboard, and assert the body contains neither the
      sentinel nor any `DIFFICULTY_LEVELS` word. The app cannot produce that
      state, which is the point — the spec pins that no answer-form partial
      would render the field if it somehow existed.
- [ ] After `POST /responses/:id/review`, difficulty is persisted under
      `ai_review[section]["difficulty"]` and rendered on the submitted
      dashboard.

---

## Task 6: Docs

- [ ] A `## Key Design Decisions` bullet in `CLAUDE.md` stating the
      review-time/content-only choice, the no-`daily_response` signature as the
      guarantee, the `duck_section_context` reuse, and the +1-call cost.
- [ ] `CLAUDE.md`'s model table calls `DailyResponse` a "rating enum" — stale;
      it is the `section_ratings` jsonb plus frozen constants. Fix it, since
      this change is what sends a reader looking.

---

## Final check

- [ ] `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
- [ ] `bundle exec rubocop`
- [ ] `git diff main --stat -- spec/fixtures/prompt_snapshots/` — must be empty.
- [ ] `git diff main -- db/` — must be empty.
