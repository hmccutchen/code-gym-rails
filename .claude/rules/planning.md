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

New sessions start with one selected kind. `DaySize.initial` supplies the
size without replaying the competency gate. `PracticeSchedule::SingleSlot`
chooses a host from eligible kinds using generated-language service and
language-filtered delivered history, outstanding
needs and kind preferences. Coverage never creates an extra slot.
[Single initial exercise](../../docs/decisions/single-initial-exercise.md)
records the policy and rollout order.

Protected-practice enrollment follows its existing rollout gate.
Inactive accounts use delivered history and keep their existing concept
guidance without writing a schedule note. Enrolled accounts keep durable
format-3 continuation for kind and assignment service by generated language,
with strict format-1 and format-2 readers available for historical rows
([Protected practice opportunities](../../docs/decisions/protected-practice-opportunities.md)).
Capture under the user lock and validate again at commit.

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
  difficulty. Track changes preserve weights and exclusions. Keep kind
  selection, per-kind difficulty and future overall graduation separate.
  The historical workload rule in #715 gives no graduation threshold.
  #714 owns protected practice and variety. #718 owns kind-specific
  difficulty definitions.
- **Section kind preferences**
  (`docs/decisions/section-kind-weight-preferences.md`): Exclusions filter the
  optional pool. Optional weights settle otherwise equal optional hosts.
  The stored regular pair supplies a separate tie preference and uses
  the default weight.
- **Pattern** (`docs/decisions/daily-kinds.md`): Pattern remains eligible for
  variety. It is outside `ExerciseSection.rotatable`, the pool with How
  often and Skip controls.
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
  `section_kind_preferences_version`. `POST /learn/prepare_ladders` writes
  only the ladder into each of the user's own `ConceptReference` rows that
  has its reference text, a full reference only where there is none, and is never offered to a trial account
  (`User#writes_learn_content?`). Generation reads only the user's own ladders
  (`GenerationLadders.for(user, ...)`). `AiService::MAX_LADDER_GUIDANCE_CHARS`
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
- **Drills** (`docs/decisions/drills.md`): A drill (`ConceptDrills`)
  moves a concept to the front of `User#concepts_needing_reinforcement`
  and makes it a learning need for eligible hosts. It clears on the same
  co-favourable rating that sets mastery to standard.
  `ConceptDrills::MAX_CONCURRENT` caps drills, a group counting as one, with
  `#can_start?`/`#can_start_group?` as the one statement of it. Drills, like
  every reinforcement entry, are offered only where `DayHosts` says today can
  tag them (`concepts_needing_reinforcement(hostable:)`).
- **Daily kinds** (`docs/decisions/daily-kinds.md`): `DailyKinds.pair`
  normalizes the stored regular pair (empty means `DailyKinds::DEFAULT`).
  `DailyKinds.recorded` resolves a historical row from its plan notes.
  Slot readers use `ExerciseSection.layout(daily:)` or
  `.optional_slots(daily:)`. A new set's active kind comes from its
  manifest. `DailyKindSwap` (`PATCH /daily_kinds/:place`) changes a pair
  place under the user-row lock and writes a `DailyKindSwapEvent`. It
  refuses stale versions, repeats, a second fourth kind and a pair that
  empties an optional slot. `SectionKindSettings#keep_unrendered` preserves
  settings Setup does not show. A save from a page rendered for another
  pair returns 409 (`layout_changed`).
- **Daily sections setting** (`docs/decisions/daily-sections-setting.md`):
  Setup no longer offers a count. Stored counts and profile validation
  remain for compatibility. A count of 1 to 4 or Automatic has no effect
  on the size of a newly generated set.
- **What the plan did, on the row**
  (`docs/decisions/what-the-plan-did-on-the-row.md`):
  `daily_exercises.plan_notes` records the planned size and reason on every
  plan and the regular pair (`daily_kinds`), plus captured server
  `kind_rungs` (`DailyPlan::Result#notes`). Historical notes may contain
  coverage, shared concept and `brake` fields. The server writes notes with
  the producing plan and reads them as stored. Regeneration writes notes
  from the replacement plan.
- **Shared concept on a real struggle**
  (`docs/decisions/shared-concept-on-a-real-struggle.md`): Historical
  multi-section notes may record a shared concept. The dashboard shows the
  line only when both delivered sections carry it and keeps mastery tier
  private.
- **Waiting retention checks** (`docs/decisions/waiting-retention-checks.md`):
  `DailyPlan` reads due checks for every bucket in the user's slice plus the
  generated language's bucket in one query
  (`User#concepts_due_for_retention_check_in`);
  `ConceptMastery.due_for_retention_check` is the one definition of due. A
  check is selected or reserved only when a section today can tag it
  (`DayHosts`); the rest land on `Result#waiting_checks` as `no_slot` or
  `no_host` and are logged.
- **Coverage exception** (`docs/decisions/coverage-exception.md`):
  Historical two-section Automatic days could add a coverage section.
  Preserve that evidence when reading old rows.
- **Competency gate** (`docs/decisions/competency-gate.md`):
  The gate still interprets historical completion, effort, and recovery.
  Grade, effort and overload require current rubric and rung evidence.
  Basic completion and recovery use active core work. Supplementary bug
  hunts stay outside both paths.
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
