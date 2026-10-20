---
paths:
  - "app/services/{daily_plan,section_rotation,section_count,competency_gate,day_size,size_forecast,coverage_exception,shared_concept,day_hosts,reviewed_section_results,weighted_roll,generation_ladders}.rb"
  - "app/services/{competency_gate,coverage_exception}/**"
  - "app/models/{concept_mastery,kind_preferences,kind_difficulty,concept_drills,concept_hosts,ladder_coverage,exercise_history_entry,user,daily_exercise}.rb"
  - "app/controllers/{concept_drills,accounts,profile,api_keys}_controller.rb"
  - "app/controllers/concerns/exercise_mix_ladders.rb"
  - "app/views/api_keys/**"
  - "app/javascript/controllers/exercise_mix_controller.js"
  - "spec/**/*{daily_plan,section_rotation,section_count,competency_gate,day_size,size_forecast,coverage_exception,shared_concept,day_hosts,concept_mastery,kind_preferences,kind_difficulty,concept_drills,accounts,user_spec,exercise_mix,generation_ladders}*"
  - "app/controllers/dashboard_controller.rb"
  - "app/views/dashboard/**"
  - "app/jobs/{generate_daily_exercises_job,regenerate_exercise_job}.rb"
  - "app/models/daily_response.rb"
  - "spec/**/competency_gate/**"
  - "spec/**/*{weighted_roll,daily_exercise}*"
  - "app/models/{daily_kinds,daily_kind_swap}.rb"
  - "app/models/daily_kind_swap/**"
  - "app/controllers/daily_kinds_controller.rb"
  - "app/views/daily_kinds/**"
  - "app/javascript/controllers/daily_kind_swap_controller.js"
  - "spec/**/*daily_kind*"
---

# Day planning, sizing and mastery

Each entry states what a change must not break. An entry that names a
`docs/decisions/` doc has its full reasoning, measurements and history there;
read it before changing that area.

- **Section kind weight preferences**
  (`docs/decisions/section-kind-weight-preferences.md`): A per-kind multiplier
  (`KindPreferences::MULTIPLIERS`) leans only `SectionRotation#pick_kind`'s
  roll, after the starvation guarantee, and never touches `slot_staleness`.
  Exclusion removes a kind from the pool everywhere, `slot_staleness`
  included; validation refuses one that empties a slot. Storage is sparse, so
  an untouched user stays byte-identical to pre-feature behavior.
- **Difficulty targets and locks**
  (`docs/decisions/difficulty-targets-and-locks.md`): Per-kind level targets
  (`KindDifficulty::LEVELS`) and locks; an unset kind follows `skill_level`
  through `KindDifficulty#rung_for`. A lock suppresses `(reduced)` easing and
  both rating adjustments, first exposure included. Targets and locks change
  prompt text only: `DailyPlan`, `ConceptMastery` and `User#concepts_*` never
  read `KindDifficulty`. Weights and difficulty share
  `section_kind_preferences_version`. `POST /learn/prepare_ladders` is the one
  scoped exception to Learn's no-bulk-rewrite rule, reaches every teammate
  through the shared `ConceptReference`, and is never offered to a trial
  account (`User#prepares_ladders?`). `AiService::MAX_LADDER_GUIDANCE_CHARS`
  bounds the ladder block.
- **Drills** (`docs/decisions/drills.md`): A drill (`ConceptDrills`) only
  moves a concept to the front of `User#concepts_needing_reinforcement`; it
  never touches rotation, weights or `KindDifficulty`. It clears on the same
  co-favourable rating that sets mastery to standard.
  `ConceptDrills::MAX_CONCURRENT` caps drills, a group counting as one, with
  `#can_start?`/`#can_start_group?` as the one statement of it. Drills, like
  every reinforcement entry, are offered only where `DayHosts` says today can
  tag them (`concepts_needing_reinforcement(hostable:)`).
- **Daily kinds** (`docs/decisions/daily-kinds.md`): `DailyKinds` is the one
  authority for which kinds every set holds. `users.daily_section_kinds` is
  sparse (empty means `DailyKinds::DEFAULT`) and normalized on read; each day
  records its pair in `plan_notes["daily_kinds"]`, and a row without it reads
  as the default. That fallback covers only rows from before the feature:
  `DailyPlan::Result#notes` always writes the pair, `AiService::JudgedSet`
  requires `plan_notes`, and `daily_exercise_plan_notes_spec` lists every
  writer and fails on a new one. Every slot reader takes the pair through
  `ExerciseSection.layout(daily:)` or `.optional_slots(daily:)`; never
  re-introduce a global slot list. A default account must stay byte-identical,
  which the prompt, page and request snapshots hold. A daily fourth takes the
  fourth slot out of rotation. `CompetencyGate` reads each day's own pair. The card's swap control (`DailyKindSwap::Picker`,
  `DailyKindSwap::Consequences`) restates no pair rule: option states come
  from `DailyKindSwap.refusal`, sharing from `DayHosts`, the weeks figure
  from `CoverageException.expected_gap_weekdays` (pinned to the real planner
  by `coverage_exception_cadence_spec`), and whether coverage runs from
  `CoverageException.applies_to_day?` with the row's `brake` note.
  `DailyKindSwap` (`PATCH /daily_kinds/:place`) is the one writer of a
  non-default pair: it refuses a stale version, a repeat, a second fourth or a
  pair that empties an optional slot, saves under the user-row lock and writes
  one `DailyKindSwapEvent`. An Exercise mix save keeps every stored setting
  Setup does not render under the current pair: weights and exclusions
  outside `ExerciseSection.rotatable`, targets and locks outside `.pickable`
  (`User#keep_unrendered_preferences`). A 409 tells a page rendered for
  another pair to reload (`layout_changed`).
- **Daily sections setting** (`docs/decisions/daily-sections-setting.md`):
  `User#daily_section_count` is Automatic (nil) or a count in
  `User::DAILY_SECTION_COUNTS`. `DaySize.for` returns a fixed count before
  completion or the gate, and a fixed count never gains a coverage section.
  `ProfileController` accepts only `"automatic"` or a listed count and 422s
  anything else, since Active Record's integer cast would misread it. It is
  not part of the Exercise mix version.
- **What the plan did, on the row**
  (`docs/decisions/what-the-plan-did-on-the-row.md`):
  `daily_exercises.plan_notes` records the planned size and reason on every
  plan and the day's daily kinds (`daily_kinds`), plus coverage, shared
  concept and `brake` when they applied (`DailyPlan::Result#notes`). It is server-owned, written with the row from
  the plan that produced it and never recomputed while rendering; the size
  excludes any coverage addition, and `RegenerateExerciseJob` rewrites it from
  the new plan.
- **Shared concept on a real struggle**
  (`docs/decisions/shared-concept-on-a-real-struggle.md`):
  `SharedConcept.pick` puts a reduced-tier reinforcement concept that every
  daily kind can tag (via `DayHosts`) into both daily sections, only on a host
  nothing else needed (`SharedConcept.placeable?`), so it never evicts a drill
  or reinforcement entry. It is advisory prompt text, never enforced through
  `fixed_concepts:`. The dashboard line shows only when both delivered
  sections carry it, and it gives no reason, since saying why would expose the
  mastery tier.
- **Waiting retention checks** (`docs/decisions/waiting-retention-checks.md`):
  `DailyPlan` reads due checks for every bucket in the user's slice plus the
  generated language's bucket in one query
  (`User#concepts_due_for_retention_check_in`);
  `ConceptMastery.due_for_retention_check` is the one definition of due. A
  check is selected or reserved only when a section today can tag it
  (`DayHosts`); the rest land on `Result#waiting_checks` as `no_slot` or
  `no_host` and are logged.
- **Coverage exception** (`docs/decisions/coverage-exception.md`):
  `CoverageException` (pure) adds one optional section, from the pair's
  optional slots, to a two-section Automatic day when the brake is off and
  no exercise on the previous `CAP_WEEKDAYS` weekdays has `plan_notes["coverage"]`, picking a kind for an
  overdue check or one unseen for `GAP_WEEKDAYS`. It respects exclusions with
  no fallback, unlike rotation, on purpose: an all-excluded pool adds nothing.
  It reads hosting through `DayHosts`, and gives up the addition when the check
  would not land in it.
- **Competency gate** (`docs/decisions/competency-gate.md`): `CompetencyGate`
  earns an Automatic day's size from rubric-stamped reviews; `DaySize` takes
  the lower of it and completion, and a fixed setting wins outright. The fold
  is pure and runs forward, moves one step a day, resets to two on the brake
  (which empties the growth windows), and reads levels from `pitched_at`.
  Eased sections stay out of growth, but their too-hard rating counts toward
  the brake. Growth counts a result only when its kind was daily on its own
  day (`Day#daily`, from the row's `plan_notes`), so a change of pair never
  reclassifies past days or resets an earned size. `ReviewedSectionResults`
  decides which sections count, and `CompetencyGate::Evidence` reads every
  stamped day with no cap, since a cap would forget an earned size.
- **Pausing generation** (`docs/decisions/pausing-generation.md`):
  `User#paused_generation_at` stops only generation the user didn't ask for
  (cron and the dashboard auto-trigger), never submit or review. `PATCH
  /account/toggle_generation` is the only pause control, and its buttons post
  the state they want. A held unsubmitted set and its draft response move to
  today (`User#carry_held_set_forward!`, `#recover_held_set`) under
  `DailyExercise#with_response_locked`, clearing both regeneration columns; a
  submitted response ends the move, and it is skipped when today already has a
  set. At most one set carries forward, so an older stray still breaks
  `#current_streak`, and re-pausing never moves the `#held_exercise` floor.
- **Personalization loop** (`docs/decisions/personalization-loop.md`):
  `User#recent_performance` feeds the last 10 sessions into the generation
  prompt. A skipped section's AI grade is never skill evidence: ratings,
  `ConceptMastery.record_review!` and reinforcement read
  `DailyResponse#answered_concept_tags`, and only where today can host them.
  A skipped, due retention check is
  deferred one interval without changing tier, streak or rating, and only for
  a concept answered nowhere on that response.
