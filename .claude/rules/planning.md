---
paths:
  - "app/models/practice*.rb"
  - "app/models/practice_schedule/**"
  - "app/services/practice_generation.rb"
  - "spec/**/*practice*"
  - "app/models/concept_mastery/**"
  - "app/models/adaptation_history.rb"
  - "spec/models/adaptation_history_spec.rb"
  - "app/models/{daily_plan,section_rotation,competency_gate,day_size,size_forecast,coverage_exception,shared_concept,day_hosts,reviewed_section_results,weighted_roll,generation_ladders}.rb"
  - "app/models/competency_gate/**"
  - "app/models/coverage_exception/**"
  - "app/models/{concept_mastery,kind_preferences,kind_difficulty,concept_drills,concept_hosts,ladder_coverage,exercise_history_entry,user,daily_exercise,concept_exposure_index}.rb"
  - "app/controllers/{concept_drills,accounts,profile,api_keys}_controller.rb"
  - "app/forms/profile_update.rb"
  - "app/controllers/concerns/exercise_mix_ladders.rb"
  - "app/views/api_keys/**"
  - "app/javascript/controllers/exercise_mix_controller.js"
  - "spec/**/*{daily_plan,section_rotation,competency_gate,day_size,size_forecast,coverage_exception,shared_concept,day_hosts,concept_mastery,kind_preferences,kind_difficulty,concept_drills,accounts,user_spec,exercise_mix,generation_ladders,section_kind_settings}*"
  - "app/controllers/dashboard_controller.rb"
  - "app/views/dashboard/**"
  - "app/jobs/{generate_daily_exercises_job,regenerate_exercise_job}.rb"
  - "app/models/daily_response.rb"
  - "spec/**/competency_gate/**"
  - "spec/**/*{weighted_roll,daily_exercise}*"
  - "app/models/{daily_kinds,daily_kind_swap,section_kind_settings}.rb"
  - "app/models/{unopened_sets,scheduled_generation,missing_set_state}.rb"
  - "app/models/concerns/generation_pause.rb"
  - "app/jobs/enqueue_due_generations_job.rb"
  - "spec/**/*{unopened_set,generation_pause,automatic_pause,key_hold,scheduled_generation}*"
  - "app/models/daily_kind_swap/**"
  - "app/controllers/daily_kinds_controller.rb"
  - "app/views/daily_kinds/**"
  - "app/javascript/controllers/daily_kind_swap_controller.js"
  - "spec/**/*daily_kind*"
---

# Day planning, sizing and mastery

Protected-practice P-A enables initiation after the P-C deployment gate. Its mode, mixed
policies, within-capacity schedule, fair assignments and persistence contract
are in `docs/decisions/protected-practice-opportunities.md`. Durable v2 state
always wins over the switch. Capture under the user lock; validate again at
commit. Never add coverage for an enrolled user or spend another turn on
regeneration, movement, failure or a superseded result.

The default-on mastery writer and all compatible drill commands follow
`docs/decisions/daily-mastery-reconciliation.md`. Receipt/suffix enrollment
is checked fresh under the user lock. Active plus restorable accepted drill
intent counts toward the existing cap; planning reads materialized drill
columns only. Preserve the legacy prefix and first-core countdown guards.
Mastery eligibility must imply adaptation eligibility across registered
kinds and supported modes, so a response's own tick precedes its mastery.
A future mastery-only kind needs an explicit ordering decision.

Each entry states what a change must not break. An entry that names a
`docs/decisions/` doc has its full reasoning, measurements and history there;
read it before changing that area.

- **Track and exercise mix** (`docs/decisions/tracks.md`): Track sets baseline
  difficulty, never an initial mix preset or ongoing kind-frequency bias.
  Track changes leave weights and exclusions alone. Preserve the separation
  between kind selection, per-kind difficulty, future overall graduation and
  Automatic workload size; #715's workload rule is not a graduation threshold.
  #714 owns the protected-practice and variety direction, and #718 owns
  kind-specific difficulty definitions.
- **Section kind weight preferences**
  (`docs/decisions/section-kind-weight-preferences.md`): A per-kind multiplier
  (`KindPreferences::MULTIPLIERS`) leans only `SectionRotation#pick_kind`'s
  roll, after the starvation guarantee, and never touches `slot_staleness`.
  Exclusion removes a kind from the pool everywhere, `slot_staleness`
  included; validation refuses one that empties a slot. Storage is sparse, so
  an untouched user stays byte-identical to pre-feature behavior.
- **Pattern's rotating role** (`docs/decisions/daily-kinds.md`): Pattern is
  ordinary slot-staleness rotation unless chosen as a daily kind, not a
  member of `ExerciseSection.rotatable` with How often or Skip controls.
  Its place in every day before adaptive rotation justifies no special
  priority. The inherited tie order is unchanged and its separate group
  promises no higher or equal frequency. The decision records the available
  settings; enrolled users follow #714's stable protected-practice order.
- **Difficulty targets and locks**
  (`docs/decisions/difficulty-targets-and-locks.md`): Per-kind level targets
  (`KindDifficulty::LEVELS`) and locks; an unset kind follows `skill_level`
  through `KindDifficulty#rung_for`. Manual track changes preserve every
  explicit target and lock, even a target equal to the old or new baseline.
  A lock suppresses `(reduced)` easing and
  both rating adjustments, first exposure included. Targets and locks change
  prompt text only: `DailyPlan`, `ConceptMastery` and `User#concepts_*` never
  read `KindDifficulty`. `DailyPlan` rolls `code_review_files`
  (`CODE_REVIEW_FILE_WEIGHTS`, `:single` on a `RealSource` or `bug_hunt` day) without
  reading `KindDifficulty`; `CodeReview.file_range` turns it into a count
  with the rung later. Weights and difficulty share
  `section_kind_preferences_version`. `POST /learn/prepare_ladders` is the one
  scoped exception to Learn's no-bulk-rewrite rule, writes only the user's
  own `ConceptReference` rows, and is never offered to a trial account
  (`User#writes_learn_content?`). Generation reads only the user's ladders,
  falling back to the shared row (`GenerationLadders.for(user, ...)`). `AiService::MAX_LADDER_GUIDANCE_CHARS`
  bounds the ladder block.
- **`bug_hunt` days** (`docs/decisions/bug-hunt.md`): every weekend
  day is a `bug_hunt` day (`WEEKEND_CODE_REVIEW_MODE_WEIGHTS`), and a weekday
  rolls `CODE_REVIEW_MODE_WEIGHTS`, which holds none. `DailyPlan.for(weekend:)`
  defaults to the clock in the caller's zone; the measurement scripts pass
  `false` and plan in the user's zone. `CODE_REVIEW_MODES` lists every mode for readers asking what any day
  could hold. A `bug_hunt` day is single-file without rolling. `code_review` is not a
  planning host on it (`ExerciseSection.planning_host?`, read through
  `DayHosts`; main-track capacity counts planning hosts only), so no
  reinforcement entry, retention check, coverage check or shared concept
  is planned onto a section that moves no mastery. The picked trap's
  concept is left out of every other kind's vocabulary, which `DayHosts`
  reads, so nothing on that concept is planned onto another section either.
  The week's featured concept is left out of the kinds that hide their concept
  in the same way (`featured_concept:`), and the fourth track asks `DayHosts` too, so a
  featured `plan_review` or `ambiguity_hunt` concept waits until the week turns
  over (`docs/decisions/the-weekly-featured-concept.md`).
  `DailyPlan` still reads no `KindDifficulty`.
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
  fourth slot out of rotation. Workload reads active core work from each row, independent of daily membership. The card's swap control (`DailyKindSwap::Picker`,
  `DailyKindSwap::Consequences`) restates no pair rule: option states come
  from `DailyKindSwap.refusal`, sharing from `DayHosts`, the weeks figure
  from `CoverageException.expected_gap_weekdays` (pinned to the real planner
  by `coverage_exception_cadence_spec`), and whether coverage runs from
  `CoverageException.applies_to_day?` with the row's `brake` note.
  `DailyKinds.for` holds as many stored places as the Daily sections
  setting asks for (the pair under Automatic); places past the pair are
  chosen extra sections in every set. The swap control, the shared concept
  (`DailyKinds.shared_pair`) and the emptied-slot check read the pair alone;
  a swap ignores, and drops on a clash, an extra the setting hides. When a
  fixed count leaves nothing to rotate (`DailyKinds.rotates?`),
  `KindPreferences.offered_to` offers only the held kinds.
  `DailyKindSwap` (`PATCH /daily_kinds/:place`) writes a pair place, and
  `ProfileUpdate` writes the whole list with a Daily sections choice. A swap
  refuses a stale version, a repeat, a second fourth or a pair that empties
  an optional slot, saves under the user-row lock and writes one
  `DailyKindSwapEvent`. An Exercise mix save keeps every stored setting
  Setup does not render under the current pair: weights and exclusions
  outside `ExerciseSection.rotatable`, targets and locks outside `.pickable`
  (`SectionKindSettings#keep_unrendered`). A 409 tells a page rendered for
  another pair to reload (`layout_changed`).
- **Daily sections setting** (`docs/decisions/daily-sections-setting.md`):
  `User#daily_section_count` is Automatic (nil) or a count in
  `User::DAILY_SECTION_COUNTS` (1 to 4; Automatic's floors stay at the pair).
  `DailyPlan.size_for` returns a fixed count before querying the gate, and a
  fixed count never gains a coverage section. Setup asks which daily section
  a count of 1 keeps and which kinds a larger count adds, and saves the count
  and the place list in one `PATCH /profile` (`DailySectionsChoice`); a count
  of 3 or 4 without a kind for every place is a 422.
  `ProfileUpdate` accepts only `"automatic"` or a whole number, since Active
  Record's integer cast would misread anything else, and `User` 422s a count
  outside the range. It is not part of the Exercise mix version.
- **What the plan did, on the row**
  (`docs/decisions/what-the-plan-did-on-the-row.md`):
  `daily_exercises.plan_notes` records the planned size and reason on every
  plan and the day's daily kinds (`daily_kinds`), plus captured server
  `kind_rungs`, coverage, shared
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
  optional slots, to a two-section Automatic day when the workload safety hold is off and
  no exercise on the previous `CAP_WEEKDAYS` weekdays has `plan_notes["coverage"]`, picking a kind for an
  overdue check or one unseen for `GAP_WEEKDAYS`. It respects exclusions with
  no fallback, unlike rotation, on purpose: an all-excluded pool adds nothing.
  It reads hosting through `DayHosts`, and gives up the addition when the check
  would not land in it.
- **Competency gate** (`docs/decisions/competency-gate.md`): `CompetencyGate`
  owns Automatic size and replays all eligible history without a cap.
  Growth needs independent five-attempt normal-grade proof per kind plus
  two full core sets at the current workload. Kind effort tracks known
  nominal-rung observations separately; eased hard counts, eased comfort
  does not. Actual skips and broad overload reduce one, retaining kind
  windows; two comfortable full sets reopen growth. Grade/effort/overload
  retain current-rubric/rung requirements; basic completion/recovery do
  not. Server as-planned rung snapshots reset only changed-kind windows,
  with observed-rung fallback for legacy rows. Supplementary bug hunts
  affect none of these paths. Coverage remains, blocked by persistent
  safety hold; protected practice and #264 checkpointing remain separate.
- **Pausing generation** (`docs/decisions/pausing-generation.md`):
  `User#paused_generation_at` stops only generation the user didn't ask for
  (cron and the dashboard auto-trigger), never submit or review. A pause has
  a source, `manual` or `automatic` (`GenerationPause`): the hourly hand-out
  pauses an account as `automatic` when `UnopenedSets` (pure) says its last
  `PAUSE_AFTER` sets ended their day unopened and unsaved, and sends no
  notice. It skips that check while a migration is pending
  (`SchemaWait.migrations_pending?`), since the `opened_at` fill may not have
  run. `paused_generation_at` is the authority: a pause with no source
  reads as manual, a source with no pause time is ignored, and no validation
  ties the two columns. `User#pause_generation!` and
  `#clear_generation_pause!` are the only writers, both in the concern; the
  hand-out pauses through `#pause_for_unopened_sets!`, which decides again
  under the user row lock. `PATCH /account/toggle_generation` is the one pause
  action; the Account buttons and the dashboard's automatic-pause line
  (Resume, Keep it paused) post the state they want, and it returns to the
  dashboard only for the fixed name `return_to=dashboard`, never a URL. The
  line is drawn outside `MissingSetState`. `opened_at` means first shown on the
  dashboard, or acknowledged by resuming generation:
  `DailyExercise#mark_opened!` stamps it once when the dashboard shows a
  finished set to its owner, and every resume stamps the sets that count as
  unopened (`DailyExercise.acknowledge_unopened!`, in the transaction that
  clears the pause), so a resume gives three fresh chances. "Keep it paused"
  acknowledges nothing, and neither does a resume on an account that is not
  paused. `DailyExercise.unopened_before` and
  `UnopenedSets.unopened?` are one rule, held equal by a spec. The key hold is a separate rule
  (`.claude/rules/providers.md`). A held unsubmitted set and its draft response move to
  today (`User#carry_held_set_forward!`, `#recover_held_set`) under
  `DailyExercise#with_response_locked`, clearing both regeneration columns; a
  submitted response ends the move, and it is skipped when today already has a
  set. At most one set carries forward, so an older stray still breaks
  `#current_streak`, and re-pausing never moves the `#held_exercise` floor.
- **Personalization loop** (`docs/decisions/personalization-loop.md`):
  `DailyResponse#assessed_sections` requires submitted, answered, validly
  graded sections; valid partial reviews contribute immediately.
  `AdaptationHistory.recent` filters before each consumer's unchanged count
  window. Completion requires every answered active section assessed, with
  skips owing no walkthrough. Unknown completion is absent, never zero.
  Delivered/scheduled rotation history stays independent of performance.
  `User#recent_performance` and `#recent_delivered_content` feed separate
  assessment and repetition-only prompt inputs. Reinforcement resolves only
  eligible hostable evidence; explicit drills remain independent.
  A skipped, due retention check is
  deferred one interval without changing tier, streak or rating, and only for
  a concept answered nowhere on that response.
