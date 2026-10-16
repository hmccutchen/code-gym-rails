# Competency gate

`CompetencyGate` decides how many sections an
Automatic day may hold from reviewed work, and `DaySize` composes it with
the completion rule and the Daily sections setting.

**How a day is sized.** `DailyPlan.size_for` runs `CompetencyGate.for`
once per plan, since it replays every post-rubric day, and hands
`DaySize.for` plain values: the setting, `SectionCount.for(history)` and the
gate's `Plan`. A fixed setting returns its count with reason `:setting` and
ignores the gate, the brake and coverage. Automatic takes the lower of
completion and the gate, clamped to `SectionCount::FLOOR..MAX_SECTIONS`,
and names which bound decided: `:completion` whenever completion alone
would give the same count, otherwise `:gate`, or `:brake` when the gate's
reason is the brake. The coverage exception then adds at most one section
as before, with `brake: DaySize::Decision#brake?`, so `CoverageException`
keeps one caller (`DailyPlan.coverage_for`). The decision rides on
`DailyPlan::Result#size`, and its count and reason go into `plan_notes`.
`SectionCount` is the completion rule alone; `DaySize` owns a fixed
setting's precedence.

**Every account starts at two.** The gate reads rubric-stamped reviews
only, so an account grows past two only as favourable, rubric-graded work
accumulates, whatever its completion. A replay of the two active
production accounts' history on 2026-10-01, under these constants, gave
size 2 on every day: completion alone gives two, since about one section a
day is answered, and earlier days had no stamped evidence to grow from.
Every AI rating in that history predates the rubric, so the replay checked
completion and self-ratings, not the AI bar. Raising `RUBRIC_VERSION`
restarts every Automatic account at two the same way, since the gate then
finds no review stamped with the new version. Specs follow the
same start: a spec that answers an optional section asks for a full day,
through `create_fake_provider_user(daily_section_count:)`, the setting, or
by stubbing the gate open (`DailyPlanGateStubs` in `daily_plan_spec`),
rather than relying on a new account getting four.

**Logs.** `AiService#draft_exercise` logs `[set_size] user=… date=… {…}`
as soon as the plan is decided, before the provider is contacted, so fixed
settings, weekends, regeneration and attempts that later fail all leave
one. Its JSON is `DaySize::Decision#diagnostics`: count, reason, setting,
completion, and the gate's count, reason and evidence (`to_three` and
`to_four` with required, available, `bar_met` and favourable counts and
`by_kind`; the brake window; optional-day completion; levels). No
answer-key field is in it. When the latest earlier row's planned size
(`DailyExercise.planned_size_before`) differs, a second line records
`[set_size] user=… from=… to=… reason=…`; it compares planned counts and
never infers a change from the reason. The successful
`[difficulty_diagnostics]` payload carries the same decision under
`requested.size`, beside `coverage` and `shared_concept`.

**What the dashboard says.** In the submitted state, on Automatic only,
`SizeForecast` composes tomorrow's size through `DailyPlan.size_for` with
today's submission in the completion history and today's review in the
gate, and compares it with the size today's plan delivered: `plan_notes`'
size plus one when it records a coverage addition
(`DailyExercise#planned_size_with_coverage`), so a coverage day never
promises a larger set of the size it already showed.
`dashboard.size_change.larger` ("Your recent answers qualify you for a
larger set.") shows when tomorrow's composed count is larger, so a gate
increase that completion still blocks says nothing.
`dashboard.size_change.smaller` names tomorrow's count, which
`SizeForecast::Change` carries, and shows only when the brake is the
reason and tomorrow is smaller. Neither shows for a fixed setting, which
also skips the gate's query, for a day whose size came from a fixed
setting (`size_reason` `setting`), since a switch to Automatic is not the
engineer's answers, nor for a row with no recorded size. There is no score,
tier or badge. The forecast adds the gate's query to each submitted-state
load: timed at about 15 ms with 60 reviewed days and 58 ms with 250, it
grows linearly with post-rubric history.

**The rule.** The gate starts at two and folds over the user's reviewed
days, oldest first. After each day: two `too_hard` self-ratings among the
latest four results of any kind (`BRAKE`) return it to two; otherwise, at
two, 4 favourable of the latest 5 fixed-kind results (`GROW_TO_THREE`)
grow it to three; at three, 8 of the latest 10 (`GROW_TO_FOUR`) grow it to
four, but only when the optional sections were all answered on each of the
last `OPTIONAL_RUN` days that had any. Otherwise it holds. A window with
fewer results than its size never meets its rule, and the gate moves at
most one step a day. Favourable means an AI rating at or above `BAR`
(`solid`) together with a favourable self-rating, the same co-favourable
shape `RungLedger` uses, because the AI rating's level calibration is
unverified. These values are a starting policy, not thresholds history
has validated.

**A brake restarts growth.** On every day the brake holds, the fixed-kind
growth windows start empty, so growing again needs a full window of
results that came after it. Without that, a user who struggles only on
optional sections would swing from three to two and straight back to
three on fixed-kind results earned before the struggle. The brake's own
window is untouched, so the reason stays `:brake` while the too-hard
results remain in it.

**Eased sections reach the brake only.** An eased section answered an
easier question than its rung, so its AI rating stays out of the growth
windows, but its too-hard self-rating counts toward the brake: a struggle
on a reduced-tier concept is the clearest one there is.

**Levels come from the evidence, as of each day.** A kind's level is the
`pitched_at` of its latest result so far, never today's target applied
backwards. When it changes, that kind's earlier results leave the windows,
even if it later returns to a level it held before. The earned count and
other kinds' results stay, so a level change alone never takes back a size.
Because the fold is pure and runs forward, adding a day cannot change how
an earlier day was decided.

**Evidence.** `ReviewedSectionResults` is the shared rule for which
sections count: answered, graded from the closed rating list, and stamped
with a rung. Eased sections are left out unless a caller asks for them,
and each result says whether it was eased. It also states the rating
rules the gate and `LevelSuggestion` read: `at_or_above?` reads
`ConceptMastery::AI_RATING_RANK`, `favourable?(bar:)` adds
`DailyResponse::SELF_RATING_FAVORABLE`, and `too_hard?` reads
`DailyResponse::SELF_RATING_UNFAVORABLE`. `LevelSuggestion::Result` asks
`at_or_above?` with `FAVOURABLE_BAR`, the lowest favourable rating, and
`too_hard?` apart from it, since its AI rating decides without the
self-rating's agreement; `CompetencyGate::BAR` is that same constant.
`ConceptMastery.record_review!` and `RungLedger` predate the class and
still read the rating lists directly; folding them in is a separate
change. A row whose
review, answers, ratings or problem set is not a hash, or a section whose
review is not one, is skipped rather than raised on, since the gate runs
on every plan, fixed settings included. `LevelSuggestion::Evidence`
delegates to it with its 60-response cap, eased sections left out and the
rubric stamp required, so generation code never names track code.
`CompetencyGate::Evidence` asks it for eased sections too, requires the
current `RUBRIC_VERSION` stamp, and reads every rubric-stamped day with no cap, in
batches ordered by date and id. A cap would forget a size whose earning days
had aged out; the batches bound memory, not history, so the query grows
with post-rubric history. A day graded before the rubric adds neither
results nor optional-section history. Each day reaches the fold as a
`CompetencyGate::Day` whose `optional` is `:none`, `:incomplete` or
`:complete`. The fold builds a `Plan`'s evidence (required, available,
AI-bar and favourable counts, per-kind counts and levels) only for a plan a
caller reads: `.plan` and `.for` return it for the last day, and `.plans`
only with `evidence: true`. The `[set_size]` line logs it.
