# Scenario source expansion: education-domain RealSource entries, and game/animation scenario flavor

Status: implemented, as two separate commits.

Two independent changes with one origin. Part 1 touches the real-source registry,
Part 2 touches fictional scenario framing, and they are committed separately because
they change different mechanisms. Neither needs a migration.

## Context

Every section plants one findable defect from a closed concept vocabulary and dresses it
in a business scenario. The scenario never changes which concept is chosen or how the
section is graded. An earlier idea was to teach genuinely new concepts from
personal-interest domains. A real test killed it: a game-dev `code_review` planted a
frame-rate-coupled velocity, and solving it needed background knowledge (browser render
loops are hardware-dependent) that has to be known rather than reasoned to.
`ConceptReference` explains only the tagged concept, so a domain prerequisite the
scenario assumes has no safety net. That is worse friction than the staleness it was
meant to fix.

Two domain-appropriate resolutions follow:

- **Game development and animation** become scenario flavor only. The planted defect
  stays a Rails/JS vocabulary concept. Part 2.
- **Education apps** use `RealSource`, because Code Gym is a working education app and
  the engineer's lived context in it supplies the domain fluency a fictional scenario
  cannot. Part 1.

## Investigation findings that shape both parts

**There is no self-reference guardrail to remove.** A search of `app/`, `spec/`,
`docs/`, `.github/` and `CLAUDE.md` for "self-referen", "Code Gym itself",
"generic scenario", "accidental" and every "Code Gym" mention finds no rule against
self-referential framing. What exists points the other way:

- `RealSource::Method#instruction` says "Keep the real class, method, and variable
  names; do not rewrite it into a fictional domain" — self-reference is mandatory on a
  grounded day.
- `ExerciseSection::AmbiguityHunt.schema_fragment` scopes its scenario TO Code Gym
  ("drawn from Code Gym-style feature requests (e.g. a daily-practice app's own
  features)").
- `real_source.rb`'s header says the lists exist for exercise quality, not safety, and
  that every file is eligible.

So Part 1's "revise the guardrail" is documentary: state in `real_source.rb`'s header and
in `CLAUDE.md` that self-reference is the deliberate choice and why the education-domain
pool exists. Nothing is deleted.

**How SCENARIO_DOMAINS actually works today** (`app/services/ai_service.rb`):

- `SCENARIO_DOMAINS` is one flat frozen list of 9 flavors.
- It reaches the provider through exactly one prompt line in `build_exercise_prompt`: "Prefer drawing each section's business-domain scenario from real,
  job-adjacent flavors like: <list minus legacy_graphql>…", followed by the legacy
  GraphQL "at most roughly 1 in every 8-10 sessions" clause.
- It is global. Nothing selects per kind, nothing rolls, nothing records what was used.
  The model picks. Every kind's `schema_fragment` declares a `scenario` field; the
  global line is what fills it.
- The only frequency rule is prompt text. `DailyPlan`'s comment on
  `CODE_REVIEW_MODE_WEIGHTS` records that this shape failed for the test-file mode
  ("nothing decided or recorded the mode") and was replaced by `WeightedRoll`. The 70/30
  split follows that precedent: a per-day `WeightedRoll` in
  `DailyPlan`, carried on `Result`, rendered by the existing line.
- `spec/services/ai_service_spec.rb`'s `SCENARIO_DOMAINS` group pins the list at exactly 9
  entries and disjoint from the tracked vocabularies; its prompt examples pin the line's
  wording ("adapt any flavor to fit the day's stack", "1 in every 8-10", "never as the
  tagged concept").
- `spec/services/generation_prompt_characterization_spec.rb` pins the prompt byte for
  byte across 72 snapshots (2 languages × 4 thirds × 3 fourths × 3 modes). It calls
  `build_exercise_prompt` with explicit kwargs and no scenario flavor, so an additive
  kwarg defaulting to the general pool leaves those snapshots valid. Rebaseline with
  `UPDATE_PROMPT_SNAPSHOTS=1 bundle exec rspec spec/services/generation_prompt_characterization_spec.rb`
  only for the deliberate ambiguity_hunt wording change below.
- `User#recent_performance` sends each prior day's
  `scenario` strings back as "framings:" so the model avoids reuse. A 70% pool is
  compatible with that as long as the pool lists settings as examples, the way the
  current line says "flavors like:", not as a closed list.

**Per-kind applicability** (each kind's `generation_guidance` and `schema_fragment` in
`app/models/exercise_section/*.rb`). The brief asked for this to be reported before
anything was applied broadly, so the table is the record of that check:

| Kind | Reads SCENARIO_DOMAINS today? | Finding | Decision |
|---|---|---|---|
| `code_review` (application_code, test_file, schema_review — toy days) | Yes, the global line | Snippet or migration in a game setting is ordinary Rails/JS code. On a `RealSource` day `ProblemSetIngest`'s real-source stamp overwrites `scenario` with the server's own string, so flavor never touches a grounded section. Correct by construction, no change. | Include |
| `pattern` | Yes | Conceptual question with a setting; nothing kind-specific about the setting. | Include |
| `challenge` | Yes | Starter code in a game setting is the same shape as any other. | Include |
| `security_review` | Yes | "A game's inventory trading endpoint" hosts IDOR, mass assignment, etc. exactly as an order endpoint does. Vocabulary restriction is untouched. | Include |
| `parsons_problem` | Yes (not in the brief's list, reported for completeness) | Blocks are a short ordered sequence with a scenario line; setting is naming only. | Include |
| `architecture` | Yes, the same global line. No separate mechanism: its kind only adds shape constraints (2-3 sentences, ~50 words, 2-3 concrete constraints, real numbers). | Compatible, but this is the kind most likely to drift into domain internals (tick rates, netcode, server authority). The prompt's new "setting supplies names and story only" sentence carries that. | Include |
| `plan_review` | Yes, the same global line. No separate mechanism. | A prose plan for a game feature reads like any other plan. | Include |
| `pseudocode_to_code` | Yes, the same global line. Its guidance forbids naming `#{label}` APIs, not settings. | A setting stated as behavior and inputs ("given a sequence of edits and undo/redo commands, produce the final state") is compatible. The no-internals sentence forbids the one incompatible shape ("apply gravity each frame"). | Include |
| `ambiguity_hunt` | No. Its `schema_fragment` overrides the global line with "Code Gym-style feature requests (e.g. a daily-practice app's own features)". | That override exists to remove the burden of an unfamiliar business context while reasoning about ambiguity. A game setting works directly against it. | **Exclude explicitly** (wording change in the fragment, below) |

---

## Part 1: education-domain RealSource entries

Scope: entries in `RealSource::APPLICATION_CODE` and `RealSource::SCHEMA_REVIEW`
(`app/models/real_source.rb`), the header comment, the spec that holds every
entry resolvable and inside `MIN_LINES..MAX_LINES` (5..40), `CLAUDE.md`. No new class,
no new mechanism, no change to `WEIGHTS`, `.pick`, `.last_seen_for`, ingest, or grading.
No migration.

### Selection discipline

Same bar as the existing entries, plus the education-domain test from the brief:

1. Self-contained: readable without the private helpers it calls, or with helpers whose
   names say what they do.
2. A real, general defect shape can be planted: moving a parent without its dependent,
   an off-by-one window, reading state after the write, a missing rollback, a wrong
   comparison direction.
3. Reads as "an education app" — progress state, resumable state, spaced repetition,
   mastery tiers, adaptive selection — so solving it needs only that general domain
   shape, never Code Gym's internal mechanics (no dependence on knowing what a
   `ConceptBucket` is, what the fourth slot means, or how `Solid Queue` permits work).
4. Inside 5..40 lines, def..end inclusive.

### Candidates

Line counts below were computed with the same Prism slicing `RealSource::Method#text`
uses (def..end inclusive); migrations are whole-file counts. All sit inside 5..40.

**`APPLICATION_CODE` — append these ten, in this order** (append, because
`daily_plan_spec`'s "prefers what this user has not seen" example reads `.first`/`.second`, and list order is the never-seen drain
order):

| File | Method | Lines | Education-domain shape | Plantable general defect |
|---|---|---|---|---|
| `app/models/user.rb` | `resume_generation!` | 11 | Lifting a pause re-dates the held, unsubmitted set onto today under a row lock | Clear the pause flag before reading the held set (the read guards on the flag, so the set is stranded forever); drop the lock so a double-tap moves twice; invert the "today already has a row" check so the move collides with the unique index. Confirmed good: a sample built from it was validated directly. |
| `app/models/user.rb` | `held_exercise` | 11 | Which stranded set a pause is holding: newest unsubmitted one dated in the pause window | `paused_on...Date.current` → `..` (today's set becomes "held" and collides with itself); `left_joins` → `joins` (a day never opened stops being held); drop `submitted_at: nil` (a finished set is carried forward). Pairs with the entry above so the pool carries the guard fact. |
| `app/models/concept_mastery.rb` | `retention_schedule_for` | 21 | Spaced-repetition interval: initial, doubled only when the scheduled check was actually due, capped | Growth applied unconditionally; `.min` → `.max` (cap becomes floor); next check counted from the reviewed day instead of today (a late review schedules a check already in the past); `mastered_at` overwritten on every pass. Self-contained. |
| `app/models/concept_mastery.rb` | `record_review!` | 25 | Once-per-day cooldown countdown for a paused concept, then per-concept evaluation | Countdown outside the once-per-day gate (double-decrement on retry); `<= 0` → `< 0`; paused promotes straight to standard instead of reduced; write the remaining count before reading it. |
| `app/services/section_count.rb` | `capped_window` | 13 | Which recent sessions count toward adaptive sizing: skip runs past a cap are dropped so older real sessions backfill | Run counter reset in the wrong branch (absence compounds forever); `<=` → `<` on the cap; window sliced before the filter. Pure, no collaborators. |
| `app/services/daily_plan.rb` | `retention_checks_for` | 8 | Which due retention checks claim the reserved slot, ranked by overdue ratio after an un-truncated fetch | Pass `limit: slots` into the SQL so raw-date ordering discards the row the ratio re-rank would pick (a real historical bug shape); drop the sign so least-overdue wins. |
| `app/models/daily_response.rb` | `improved_code_visible?` | 15 | Reveal the corrected answer only from a concept's second exposure on | `>= 2` → `>= 1` (reveal on first exposure defeats retrieval practice); count exposures up to today instead of up to the response's own date (viewing history reveals retroactively). |
| `app/jobs/generate_daily_exercises_job.rb` | `generate_if_due` | 11 | The hourly tick: generate and send "ready" on the first tick of a weekday morning, nudge on later ticks | Hour comparison off by one; the `exists?` fork collapsed into a bail-out so no nudge ever fires; remind in both branches (a push every hour). |
| `app/jobs/send_push_reminder_job.rb` | `stage_for` | 9 | How far through an unfinished day the learner is: untouched, partway, unrated, unsubmitted | `<` → `<=` on the answered count (a complete set reads as partway); stage checks reordered; denominator from raw keys instead of the day's active sections. |
| `app/controllers/daily_exercises_controller.rb` | `claim_regeneration!` | 7 | Atomic once-per-day claim with a stale-claim retake | Drop `regenerated_at: nil` (unlimited regenerations); `== 1` → `.positive?`; stale-window comparison inverted. |

Pool grows from 11 to 21. At `WEIGHTS[:real]` = 0.35 and an application_code day roughly
every three, a given method resurfaces about every four months under least-recently-seen,
up from two. `user.rb` goes from three entries to five of twenty-one, which is not
dominance, and is why `concept_exposure_index` is held back below.

**`SCHEMA_REVIEW` — append these four:**

| Migration | Lines | Structure to get wrong |
|---|---|---|
| `db/migrate/20260723010000_create_concept_masteries.rb` | 15 | `t.references` with FK, `null: false, default: 0` counters, composite unique index on `[user_id, concept, language]`. Drop `language` from the index and a mixed-language learner's two masteries collide; drop `unique:` and `find_or_initialize_by` picks arbitrarily. |
| `db/migrate/20260101000003_create_daily_responses.rb` | 19 | Two FK references, jsonb `answers` with default and `null: false`, `submitted_at`, and the `[user_id, date]` unique index that the carry-forward entries above collide against. Index on `[user_id, daily_exercise_id]` instead is exactly the "parent moved without its dependent" shape. |
| `db/migrate/20260723000000_add_section_ratings_to_daily_responses.rb` | 28 | Real `up`/`down` with a rename and a `change_column ... USING CASE` backfill. A `down` that is not the inverse of `up`; the enum mapping off by one; rename and convert reordered. The only up/down-with-backfill migration on a progress table. |
| `db/migrate/20260728000004_add_retention_schedule_to_concept_masteries.rb` | 8 | Three retention columns plus a `[user_id, next_retention_check_on]` index. Column order reversed (useless for the per-user due range); `:datetime` for a date; `null: false, default: 0` on an interval the code reads as nullable-means-cleared. Thin, but the `Migration` instruction asks for a ~10-15 line migration modelled on it, so thinness costs less than for a method. |

Pool grows from 4 to 8; a given migration resurfaces about every two months instead of
monthly, which the original design named as the reason to grow this pool first.

**Considered and held back**, with the reason, so the next curation pass does not
re-derive them:

- `ConceptMastery.evaluate_concept!` (40) — the richest tier-walk material, but it sits
  exactly at `MAX_LINES`; the next one-line edit evicts it via the drift spec. Add it
  if it ever shrinks or the bound is raised deliberately.
- `User#concept_exposure_index` (17) — good general shape (`|=` vs `<<` double-counts
  one day); held back only to keep `user.rb` at five entries.
- `AccountsController#toggle_generation` (20) — overlaps `resume_generation!`.
- `User#concepts_needing_reinforcement` (29) — four collaborators and a 30-line comment
  carrying the dedup-before-filter rule; the subtle flaws need bucket knowledge.
- `User#concepts_overdue_for_retention_check` (10) — the vocabulary-vs-language
  distinction is Code Gym internals, fails criterion 3.
- `DailyPlan.fourth_track` (19) — needs the fourth-slot model to read; fails criterion 3.
- `SectionRotation.for` (10) — fine material, but `pick_kind` from the same file is
  already listed.
- `create_daily_exercises` (14) — companion to `create_daily_responses`, less structure.
- Every `add_column`-only progress migration (`add_paused_generation_at_to_users`,
  `add_reviewing_since_to_daily_responses`, and the like) — nothing structural to plant,
  the same reason `add_adaptive_set_size_to_users` was left out originally.

### Guardrail revision (documentary only)

- `real_source.rb` header: keep the existing "quality, not safety" paragraph and add
  that grounding in Code Gym's own code is deliberate — the engineer's lived context in
  this app is what supplies the education-domain fluency a fictional learning-app
  scenario cannot, so a self-referential framing here is the point rather than a leak
  into an otherwise generic scenario. The existing safeguards (curated list, one planted
  flaw in a modified copy, scenario says the copy is altered, never the unmodified
  original) are the whole guardrail.
- Per-entry rationale lives in the design doc's table (the way the starter pool is
  documented in `docs/superpowers/specs/2026-09-11-real-source-code-review-design.md`),
  not as per-line comments in the constant.

### Tests (Part 1)

- `spec/models/real_source_spec.rb` needs no new examples for new entries: "every
  curated entry" already asserts resolvable, inside the bounds, unique id, correct class.
  Run it; the line-count bound is the acceptance test for each new entry.
- `spec/services/daily_plan_spec.rb`'s "prefers what this user has not seen" example reads
  `APPLICATION_CODE.first`/`.second`, so new entries must be appended, not inserted at
  the top. Note in the spec doc that append order also sets the never-seen drain order.
- Nothing else changes. `problem_set_ingest_spec` and `ai_service_spec`'s grounded
  examples read `APPLICATION_CODE.first` and `SCHEMA_REVIEW.first`, both unchanged.

### Files (Part 1)

- `app/models/real_source.rb` — new entries appended to both lists, header paragraph.
- `docs/superpowers/specs/2026-09-18-scenario-source-expansion-design.md` — this document.
- `CLAUDE.md` — in the "code_review content modes" bullet, one sentence on the
  education-domain pool and why self-reference is deliberate there.

---

## Part 2: game-dev and animation scenario flavor, 70/30 per day

Scope: a second scenario pool, a per-day roll in `DailyPlan`, one kwarg threaded to the
prompt and the diagnostics log, one wording change in `AmbiguityHunt.schema_fragment`.
No new concept, no vocabulary change, no change to concept selection, grading,
`ConceptMastery`, retention or difficulty. No migration. Not persisted: like
`code_review_mode`, the flavor is rolled, prompted, logged and gone; the scenario text
itself already persists in `problem_set` and comes back as "framings:".

### The pools (`app/services/ai_service.rb`, beside `SCENARIO_DOMAINS`)

Keep `SCENARIO_DOMAINS` exactly as it is (the general pool; its 9-entry spec pin stays).
Add:

```ruby
# Game-development and animation-tooling SETTINGS for the scenario field, used
# the same way SCENARIO_DOMAINS is: prompt-level framing only, never a concept,
# never read by ProblemSetIngest or any mastery bucket. Each names a system an
# ordinary web engineer would build — a save-state store, an undo stack, a
# leaderboard — never one whose defect needs game or animation internals to
# see. A frame-rate-coupled velocity was tried and failed for exactly that
# reason: the fix needed a domain fact rather than reasoning from the code.
GAME_AND_ANIMATION_SCENARIO_DOMAINS = %w[
  platformer_save_state_system
  game_inventory_and_crafting
  level_editor_undo_redo_stack
  animation_timeline_keyframe_editor
  leaderboard_and_season_rankings
  matchmaking_lobby_queue
  sprite_and_audio_asset_pipeline
  achievement_unlock_tracking
  replay_recording_and_playback
  in_game_marketplace_and_trading
  animation_render_export_queue
].freeze

# Keyed by flavor; DailyPlan::SCENARIO_FLAVOR_WEIGHTS rolls over the same keys
# and a spec holds the two key sets equal, so a flavor cannot be rolled that
# has no pool or listed that is never rolled.
SCENARIO_POOLS = {
  general:            SCENARIO_DOMAINS,
  game_and_animation: GAME_AND_ANIMATION_SCENARIO_DOMAINS
}.freeze
```

Entry criteria: concrete, backend-or-state shaped, adaptable to either stack (a Rails
day builds the save-state store; a JS day builds the editor's state), and free of
physics, rendering, frame loops, shaders, collision and netcode. `legacy_graphql_maintenance`
stays in the general pool only; the rare-use clause renders on both flavors unchanged.

### The roll (`app/services/daily_plan.rb`)

```ruby
Result = Data.define(..., :code_review_mode, :code_review_source, :scenario_flavor)

# Which scenario pool today's prompt offers. Leaned hard toward the flavor the
# engineer asked for, with a floor for the general pool rather than none:
# an exclusive pool relocates the staleness this exists to fix into a smaller
# fixed pool, and a familiar setting starts to predict the bug. Rolled once per
# day, not per section, the same shape as CODE_REVIEW_MODE_WEIGHTS, and for the
# same reason a prompt-stated "roughly 7 in 10" was rejected: nothing would
# decide or record it.
SCENARIO_FLAVOR_WEIGHTS = { game_and_animation: 0.7, general: 0.3 }.freeze
```

In `.for`: `scenario_flavor: WeightedRoll.pick(SCENARIO_FLAVOR_WEIGHTS)` on the
`Result.new` call. No gate: every language and every kind set gets a flavor.

### The prompt (`AiService#build_exercise_prompt`)

- Add `scenario_flavor: :general` to the kwarg list. Fifth instance of the
  additive-kwarg pattern after `cache_system:`, `max_tokens:`, `history:` and
  `code_review_source:` — every existing caller and all 72 snapshots render byte-identical.
- Replace the inline `scenario_domain_list` local and the prompt line with one private method, `scenario_flavor_guidance(flavor)`, that returns the
  whole bullet. `SCENARIO_POOLS.fetch(flavor)` so an unknown flavor fails loudly at the
  boundary rather than rendering an empty list.
  - `:general` returns today's line, byte for byte, including the legacy GraphQL clause.
  - `:game_and_animation` returns: "Prefer drawing each section's business-domain
    scenario from game-development and animation-tooling settings like: <pool,
    underscores to spaces> (adapt any flavor to fit the day's stack — e.g. a Rails day's
    "platformer save-state system" is the service that stores, versions and restores
    saves). The setting supplies names and story only: the tagged concept and the one
    planted issue stay ordinary <label> ones, and solving a section must never require
    knowing how games or animation work inside — no frame timing, physics, rendering,
    engine or netcode detail. Use a legacy GraphQL maintenance scenario (e.g. "a
    studio's legacy GraphQL layer needs a fix") only rarely — at most roughly 1 in every
    8-10 sessions — purely as scenario framing, never as the tagged concept."
  - Keep the exact phrase "adapt any flavor to fit the day's stack" on both flavors;
    `ai_service_spec` asserts it for either language.
- `#generate_exercise` passes `scenario_flavor: plan.scenario_flavor`.
- `#log_difficulty_diagnostics` adds `scenario_flavor: plan.scenario_flavor`
  to `requested`, next to `code_review_mode`, so the delivered "framings" can be read
  against the flavor that was asked for.

### The ambiguity_hunt exclusion (`app/models/exercise_section/ambiguity_hunt.rb`)

The kind already owns its override; make it explicit rather than implicit. Change the
`scenario` field description to:

> "string — the concrete business-domain framing, drawn from Code Gym-style feature
> requests (a daily-practice app's own features) and NOT from the scenario flavors
> listed above — the engineer reasons about ambiguity in a domain they already know"

This is a deliberate prompt change; rebaseline the 24 `*__ambiguity_hunt__*` snapshots
with `UPDATE_PROMPT_SNAPSHOTS=1` and confirm the other 48 are unchanged in `git diff`.
Add a short comment on the class saying why the kind opts out (unfamiliar context is
the burden this kind removes).

No branch on kind anywhere in shared code: the global line stays global, and the one
kind that opts out says so in its own fragment.

### Tests (Part 2)

`spec/services/ai_service_spec.rb`

- `GAME_AND_ANIMATION_SCENARIO_DOMAINS` is frozen, non-empty, disjoint from
  `SCENARIO_DOMAINS` and from every concept vocabulary (`RAILS_CONCEPTS`, `JS_CONCEPTS`,
  `ARCHITECTURE_CONCEPTS`, `PLAN_REVIEW_CONCEPTS`, `AMBIGUITY_HUNT_CONCEPTS`,
  `PSEUDOCODE_TO_CODE_CONCEPTS`), and none of its entries name frame, physics, render,
  shader, collision or netcode (a word-list assertion, so the criterion is a spec, not
  a comment).
- `SCENARIO_POOLS.keys` equals `DailyPlan::SCENARIO_FLAVOR_WEIGHTS.keys` (same shape as
  `model_routing_spec`'s purpose-key check).
- `build_exercise_prompt` with `scenario_flavor: :game_and_animation` includes each pool
  entry humanized, "adapt any flavor to fit the day's stack", "never require knowing how
  games or animation work inside", the legacy GraphQL clause, and does not include
  "background job processing".
- With the default flavor the prompt is unchanged: the existing legacy-GraphQL example already
  covers the general wording, and the characterization suite proves the bytes.
- `#generate_exercise` threads `plan.scenario_flavor` to the prompt and to the
  diagnostics `requested` payload (extend the existing grounded-day diagnostics example).
- An unknown flavor raises (`KeyError`) rather than rendering an empty list.

`spec/services/daily_plan_spec.rb`

- `SCENARIO_FLAVOR_WEIGHTS` sums to 1.0 and reaches both flavors at `rand` 0.0 and 0.7,
  mirroring the `CODE_REVIEW_MODE_WEIGHTS` group.
- `Result#scenario_flavor` is carried, stubbing
  `WeightedRoll.pick.with(DailyPlan::SCENARIO_FLAVOR_WEIGHTS)`.
- The difficulty-targets example stubs every `WeightedRoll.pick` to `:application_code`
  and never renders a prompt, so it still passes; an example that stubs `pick` without
  `.with` and then generates would hit the `fetch`, and none does.

`spec/services/generation_prompt_characterization_spec.rb`

- Unchanged in code. 48 snapshots unchanged, 24 ambiguity_hunt snapshots rebaselined.

No default pin in `spec/support`: like `code_review_mode`, the flavor changes only the
prompt, and a canned provider response comes back through ingest identical either way.
That is the same reasoning `real_source_default.rb` gives for not pinning the mode.

### Files (Part 2)

- `app/services/ai_service.rb` — two constants, `scenario_flavor_guidance`, the kwarg,
  `#generate_exercise`, `#log_difficulty_diagnostics`.
- `app/services/daily_plan.rb` — `Result` field, `SCENARIO_FLAVOR_WEIGHTS`, the roll.
- `app/models/exercise_section/ambiguity_hunt.rb` — schema fragment wording and comment.
- `spec/fixtures/prompt_snapshots/*__ambiguity_hunt__*.txt` — rebaselined.
- `spec/services/ai_service_spec.rb`, `spec/services/daily_plan_spec.rb` — as above.
- `CLAUDE.md` — a new "Scenario flavor" bullet under Key Design Decisions: two pools,
  per-day roll and why 30% is a floor, the ambiguity_hunt exclusion, the
  "setting supplies names and story only" rule and the failed frame-rate test behind it,
  and that the flavor is not persisted.

---
