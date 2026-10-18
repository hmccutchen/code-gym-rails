# Swap which kinds fill the daily places

Status: being built. Decided on 2026-10-16: the swap saves the pair and
starts with the user's next set. It never changes a set that already exists.
D1 is (a), at most one fourth among the daily kinds. The in-place design that
was considered and not chosen is in
`2026-10-16-daily-kind-swap-in-place-alternative.md`.
Date: 2026-10-16. Sections 1 and 2 and the table below describe
`origin/main` at `abf0892` (#404), before any of this was built.

Implementation log:

- PR A, the regeneration claim window: #406, merged.
- PR 0, the schema: #407, merged.
- PR 1, the per-user layout: #408.
- PR 1b, per-day pairs in the gate: #411, stacked on #408.
- Two additions not in the original order:
  - #413 filters history-derived reinforcement by what today's sections can
    tag, as drills already were. It changes which reinforcement concepts a
    default account is offered: one no section today can tag waits for a day
    that can.
  - #415 names every prompt section by its kind instead of its position, and
    rewrites all 263 prompt snapshots. It is a precondition for PR 2.

## Goal

Every account has a fixed number of daily places, two today, and each holds
one section kind. Each daily card gets a swap control. A swap:

- saves the chosen kind as that place's kind;
- starts with the user's next set. A set that already exists keeps the
  sections it was generated with;
- returns the swapped-out kind to the optional pool, with its past results
  kept and still counted.

Any level can swap, with no special case for juniors. A swap calls no
provider, so it is free and unlimited, as the brief asked. "The brief" is
the feature request this spec answers, written 2026-10-16 and not stored in
the repository. The picker reuses
the kind guides from #391.

"Next set" is deliberate wording, and it is not always tomorrow. Section 3
says which set a swap first applies to in each case.

## Where the code disagreed with the brief

As of `abf0892`. Each point below is something the brief assumes that main
did not match.
The design works with what is on main and does not work around these points.

| Brief says | Main says | Effect on this design |
|---|---|---|
| "Juniors default to code review and design comparison" | Every account gets them, at every level. `ExerciseSection.fixed` is `all.select(&:fixed?)`, and only `CodeReview` and `DesignComparison` return `true` (`app/models/exercise_section/code_review.rb:10`, `design_comparison.rb:38`). No rule reads the level | The default pair stays level-independent. Nothing to build for juniors |
| PR 1 of the tracks plan may not have merged and may still write presets | It merged. #398 (`f0c5c6a`) removed the junior preset and "Leave the track". `docs/decisions/tracks.md`: "No preset targets are written". #403 stopped reading `users.learning_track`, and the column drop is the only step left | No conflict and no reason to wait. The column drop touches `users`, so the swap's migration should not ship in the same release as that drop. That is a deploy-order note, not a dependency |
| "Adding other kinds by hand is a separate, existing action" | No such action exists. No controller, route or job adds a kind to today's set or to the plan. The nearest controls all change future plans only: Exercise mix weights and exclusions, the Daily sections count, drills (which move a concept, never a kind), and the automatic coverage exception | This design keeps the code and the UI open for that action without building it. The swap lives in `DailyKinds` and `DailyKindSwap`, so an "add a kind" action would get its own name and endpoint |
| "The graduation rubric" is planned work to align with | No graduation rubric, "breadth" rule or "both daily kinds" rule is written anywhere in `docs/`, `.claude/` or git history. Graduation shows up only in passing: `tracks.md` says it will reuse `TrackChange` and follow the suggestions switch | Section 5 states what graduation should read. There is nothing on main to change |
| Daily places will grow "as the section count grows" | Nothing on main plans more than two. `SectionCount::FLOOR = 2` equals `ExerciseSection.fixed.size` by convention only, and `CompetencyGate::FLOOR`, `User::DAILY_SECTION_COUNTS` and the Setup hint ("%{lowest} gives you only %{fixed_sections}") all depend on that | The count is derived, never stored, and a spec asserts `FLOOR == DailyKinds::COUNT` (section 2) |
| A daily place can hold any kind | `ExerciseSection.slots` groups the kinds, and a group resolves to **one** kind per day: `third` covers architecture, security review, challenge and Parsons, and `fourth` covers plan review, ambiguity hunt and pseudocode to code. `resolved_keys` keeps the first present key in each group | If the stored pair simply replaced `fixed?`, pinning architecture as daily would keep the other three thirds off every day. Worse, a stored row holding two thirds would lose one from `active_section_keys`. Section 2 introduces a per-user layout to fix this. Fourth kinds are limited to one daily kind (D1, decided) |
| Swaps are "free and unlimited" | Main has no cap on daily generations for own-key accounts. `/regenerate` is once a day, `/generate` is 3 an hour | Holds as written: a swap only saves the pair and makes no provider call (section 4) |

## 1. How the daily kinds were decided before this work

As of `abf0892`. #408 replaced `ExerciseSection.fixed` with `DailyKinds`, so
the call sites below now take a pair. There was no single place that holds "this user's daily kinds". It is a
class-level fact, the same for everyone, read from `ExerciseSection.fixed` by
about fifteen call sites:

- **Layout:** `ExerciseSection.slots`, `.slot_kinds` (which marks every fixed
  kind as chosen), `.resolved_keys` (fixed kinds first, so the cap never cuts
  one) and `.fixed_sections_share?`.
- **Planning:**
  - `SectionRotation::MANDATORY_SLOT_COUNT` and `OPTIONAL_SLOTS` (`section_rotation.rb:6-7`).
  - `CoverageException::OPTIONAL_KINDS` and `.applies_to_day?` (`coverage_exception.rb:10,17`).
  - `SharedConcept.pick` (`shared_concept.rb:4,8`).
  - `CompetencyGate.for` (`competency_gate.rb:39`) and, separately, `CompetencyGate::Evidence#initialize` (`evidence.rb:14`).
- **Generation:**
  - `ExerciseSection.judge_retries` (`fixed? ? 2 : 1`), read by `JudgedGeneration#resolve_rejection` and `AiService::JUDGED_GENERATION_BUDGET`.
  - `GenerationPrompt#shared_concept_line` (`generation_prompt.rb:208`).
  - `ProblemSetIngest#prune_unplanned_slots!`, `#resolved_slot_count` and `#slot_kinds_for`.
  - `AiService#log_shared_concept`.
- **Pages:**
  - `DailyExercise#shared_concept_shown?` and the dashboard hint (`dashboard/_exercise.html.erb:89`).
  - Setup's "In every set" group and its Daily sections hint (`api_keys/edit.html.erb:111,158,166`).
- **Validation:** `User#every_slot_keeps_a_kind` and `#rotatable_keys` (fixed kinds are not rotatable, so they can't be weighted or excluded).
- **Scripts:** `script/gemini_capacity_probe.rb:80,129`.

`DailyPlan.for` composes these: `DaySize` sets the count,
`SectionRotation` fills `count - 2` optional groups from `pattern`, `third` and
`fourth`, and `CoverageException` may add one. `CompetencyGate` grows the
count from results on the fixed kinds only. `KindDifficulty`,
`LevelSuggestion` and `TrackChange` never mention fixed kinds (section 5).
Neither `skill_level` nor any track decides the daily kinds.

**Decided:** build now. Nothing the tracks work still had to do touched
these call sites.

## 2. Storage, layout and the place count

The design as specified against `abf0892`. Where #408 built something
differently, `docs/decisions/daily-kinds.md` is the record and says so.

### The stored choice

- **Column.** Add `users.daily_section_kinds`, `jsonb`, default `[]`, not null.
- **Empty means the default pair.** Storage is sparse, like the kind
  preferences, so an untouched account plans, prompts and renders exactly as it
  does today.
- **Order is the place.** Index 0 is the first daily card and index 1 the second.
- **Validation runs on write.** The list must be empty, or exactly
  `DailyKinds::COUNT` distinct keys from `ExerciseSection.keys`, holding at
  most one of `ExerciseSection.fourths` (D1).

`DailyKinds` (a new value object in `app/models`) becomes the one authority:

- `DailyKinds.for(user)` returns the normalized list of kind classes.
- `DailyKinds::DEFAULT` is the registry's default pair. It replaces `fixed?`
  as a kind facet: `default_daily?` stays `true` on `CodeReview` and
  `DesignComparison`, and `ExerciseSection.fixed` is removed rather than left
  as a second answer.
- `DailyKinds::COUNT` is `DEFAULT.size`, so a third default kind raises the
  count with no other edit.

### The record on each day

`DailyPlan::Result#notes` gains `"daily_kinds"`, written on every plan.
`RegenerateExerciseJob` rewrites it from its new plan, as it already does for
`size`. This follows "what the plan did, on the row": anything that later reads
a day reads that day's own pair and never recomputes it. A row without the key
predates the feature, and the default pair was in force then, so readers fall
back to `DailyKinds::DEFAULT`.

The rules for reading a recorded pair are kept in
`docs/decisions/daily-kinds.md`. In short:

- **No backfill** (decided 2026-10-16). The fallback covers old rows only.
- **The write side guarantees the key.** `DailyPlan::Result#notes` always
  writes it, `AiService::JudgedSet` requires `plan_notes`, and
  `daily_exercise_plan_notes_spec` lists every writer and fails on a new
  one.
- **A recorded pair is read as stored,** never re-fitted to today's `COUNT`
  the way a user's setting is (below), so a past day is never reclassified.
  An unknown key is dropped, and a pair whose every key is unknown reads as
  empty, not as `DEFAULT`.

### The layout

`ExerciseSection.slots` becomes `ExerciseSection.layout(daily:)`:

- each daily kind gets a group of its own, in stored order;
- `pattern`, `third` and `fourth` follow, each minus any daily kind;
- `code_review` and `design_comparison`, when not daily, become single-kind
  optional groups like `pattern`;
- empty groups are dropped.

For the default pair this returns exactly today's `slots`, in today's order.
That order fixes the prompt's section order and the page order, so default
accounts stay byte-identical, and the existing prompt and page snapshots prove
it through #408 and #411. #415 then rewrites every prompt snapshot on purpose,
to name sections by kind; it is the one planned rewrite.

These readers take a layout instead of the global slots:

- **`ExerciseSection.resolved_keys(problem_set, daily:)`**, and
  `DailyExercise#active_section_keys`, which passes the row's
  `plan_notes["daily_kinds"]`. This one is required for correctness: without
  it a stored day holding architecture as daily plus challenge as its third
  would show only one of them.
- **`ProblemSetIngest`**: prune, the slot count and the successor kind after an
  unusable section, all with the plan's layout passed in.
- **`SectionRotation.for(history, count:, preferences:, daily:)`**: the
  mandatory count is `daily.size`, and the optional groups come from the
  layout.
- **`CoverageException`**: the candidate kinds are the layout's optional
  groups, not "every kind outside the pair", and the "two-section day" test is
  `count <= DailyKinds::COUNT`. The difference matters under D1: while a
  fourth is daily its two siblings are in no optional group, so coverage
  can't add one either and a day never holds two fourths. Coverage also keeps
  a user's exclusions final: when every candidate is excluded it adds
  nothing. Rotation instead falls back to the whole slot, because it has to
  produce a day. The two differ on purpose (decided 2026-10-16, recorded in
  `docs/decisions/coverage-exception.md`).
- **`SharedConcept.pick(..., daily:)`**: a fourth kind can never tag a language
  concept, so a pair holding a fourth never shares. That is the right outcome,
  with no special case.
- **`ExerciseSection.for_plan` / `slot_kinds`, `GenerationPrompt#kinds_for`,
  `AiService#draft_exercise` and `script/forced_concept_drafts.rb`** take the
  plan's daily kinds.
- **`judge_retries`** moves off the kind and becomes a plan fact:
  `JudgedGeneration` gives two retries to the plan's daily kinds and one to the
  rest. `JUDGED_GENERATION_BUDGET` keeps reading the maximum, which stays 2.
- **Text:** the shared-concept prompt line, `DailyExercise#shared_concept_shown?`
  and the dashboard hint name the row's daily kinds. Setup's "In every set"
  group and Daily sections hint name the user's current kinds.
- **`User#every_slot_keeps_a_kind` and `#rotatable_keys`** read the user's
  layout, so a daily kind can't be weighted or excluded. The intent is that a
  weight or exclusion already stored on a kind that becomes daily stays
  stored and is ignored while the kind is daily, then applies again when it
  goes back to the pool. That keeps storage sparse and makes a swap
  reversible. #408 does not build the "stays stored" half: the Exercise mix
  form posts only the rows on screen, so its next save drops the entry, and
  the `*_name_rotatable_kinds` validations check every stored entry. PR 2
  adds both fixes (see the PR order).

`DailyPlan::Result` gains `daily_kinds`. The `pattern`/`third`/`fourth`
fields stay, because `GenerationPrompt` and the fourth track read them.

### When the place count changes

`DailyKinds.for` normalizes the user's stored setting on read, so a list from
another release always fits. This applies to the setting only; a day's
recorded pair is read as stored (section 2, "The record on each day"):

- **Count grew:** the stored kinds keep their places, and the new place gets the
  first `DEFAULT` kind not already held.
- **Count shrank:** the list is cut from the end, so the first places keep their
  kinds.
- **Unknown key** (a kind removed from the registry), **a repeated kind or a
  second fourth kind:** that place falls back the same way as a grown count.

A user's pair is never rewritten in the database by a count change. The next
swap writes a list of the new length. Two specs pin this: one for the
normalization, and one asserting that `SectionCount::FLOOR`,
`CompetencyGate::FLOOR` and `User::DAILY_SECTION_COUNTS.min` all equal
`DailyKinds::COUNT`. Today they only happen to match.

## 3. What a swap does

A swap saves the pair, under the user-row lock, and does nothing else. It
bumps `section_kind_preferences_version`, so an Exercise mix open in another
tab gets the usual 409, and it writes one event row (section 8). It doesn't
touch today's exercise, its response, any claim or any provider.

The set on screen keeps its sections, because `plan_notes["daily_kinds"]` and
the `problem_set` were written when it was generated. That rule needs no new
code. `DailyPlan.for` reads the user's pair when a plan is made, so the first
set planned after the save uses the new pair, and every set planned before it
keeps the old one.

### Which set a swap first applies to

A swap is made from a card, so a set is always on screen when it happens.
The new pair applies to the first set *planned* after the save:

| When the swap is made | First set with the new pair |
|---|---|
| A weekday, from today's set (unsubmitted or submitted) | The next weekday's set. It is generated by the hourly cron, gated to 8am in the user's zone, or on the first dashboard visit that day, whichever comes first. A regeneration today plans from the new pair, so regenerating moves this to today (see below) |
| Friday, or a weekend set made with "Generate anyway" | Monday's set. Cron and the dashboard's automatic trigger skip weekends, so the new pair waits unless the user presses "Generate anyway" on a weekend day. That set is planned from the new pair |
| A paused account (`paused_generation_at` set) | No set is generated automatically while paused: the cron query excludes paused users, and the dashboard shows `paused_empty`. The next set is the first one the user asks for, "Generate anyway" or `/generate`, or the first weekday set after they resume. That can be days or weeks away |
| A held set carried forward (paused, unsubmitted set moved to today by `carry_held_set_forward!`) | The held set keeps its sections. It was planned before the swap, and `carry_forward` changes only its date and the regeneration columns. It moves forward again each day until it is submitted. The new pair starts with the first set generated after that, which, while still paused, means the next one the user asks for |
| Any day, followed by a regeneration of the set on screen | The regenerated set. `RegenerateExerciseJob` runs `DailyPlan` again, which reads the saved pair. This is the one way to get the new pair into today, and it costs what regeneration always costs: every answer so far and the day's one regeneration |

The reply's sentence is chosen by the server from these cases:

- **Default:** "Saved. This starts with your next set."
- **Paused:** "Saved. This starts with your next set. Generation is paused, so
  that's the next set you generate or the first one after you resume."
- **"Want it today?"**: one more line, pointing at the existing "Generate new
  set" button: "Want it in today's set? Generate a new set. This replaces
  every answer you've typed so far." The line names its cost every time it
  appears.
  - **When it shows:** only when regeneration is available *and* nothing is
    submitted. That is stricter than the button. In
    `dashboard/_exercise.html.erb` the button shows unless the response is
    reviewed, `regenerated_at` is set, or the trial has ended, so it still
    shows on a submitted but unreviewed set. Offering "apply it today" there
    would mean throwing away submitted work, so the line also requires that
    today's response is absent or has no `submitted_at`.
  - **One source for the shared part.** The button's three conditions move
    out of the view into one helper, `regeneration_offered?(exercise,
    response)`. The button reads it, and the line reads it plus "not
    submitted", so the two can't drift.
  - **The button is unchanged.** It keeps its own conditions and its confirm
    (`regenerate_confirm_with_progress`).

None of these says "tomorrow". The copy uses "your next set" everywhere.

**"Adding other kinds by hand"** doesn't exist on main (see the table above).
The swap's code and UI stay under `DailyKinds` and `DailyKindSwap`, so such an
action would get its own name and endpoint.

## 4. Cost

- **A swap makes no provider call.** It saves a user row and an event row.
  Choosing a kind is free and unlimited, with no rate limit and no per-set
  allowance.
- **The only paid path near the feature is regeneration,** which keeps its own
  rules: once a day (`claim_regenerating!(regenerated_at: nil)`), refused once
  reviewed. Swapping and then regenerating spends what a regeneration
  always spends: one call today, or a judged day after PR 4.
- **Trial accounts** are being turned off. `TrialAllowance` still wraps their
  calls inside `AiService#call_and_log`, and the swap adds nothing for them,
  since it makes no call.

## 5. Evidence after a swap

**Results are stored per kind and never tied to being daily.**

- `daily_responses.answers`, `ai_review`, `section_ratings` and `concept_tags`
  are keyed by section key.
- `problem_set` sections carry `pitched_at`, `eased` and `source` stamps.
- `ConceptMastery` is keyed by concept and bucket, with no kind at all.
- `ReviewedSectionResults` yields `(date, kind, level, ratings, eased)`.
- `ExerciseHistoryEntry` holds section keys and answered keys.

A swapped-out kind's history stays where it is and keeps counting everywhere
it counts today.

| Reader | Assumes a fixed pair? | After a swap |
|---|---|---|
| `LevelSuggestion` | No. `candidates` is every unlocked kind on the ladder, and each kind is judged on its own results ("no lead kind and no bundle") | No change. Only `docs/decisions/level-suggestions.md:37-42` changes ("only code review and design comparison can reach five" becomes "only the daily kinds") |
| `LevelSuggestion::Evidence` | No | No change |
| `KindDifficulty` | No. Rungs cover `ExerciseSection.all` | No change |
| `TrackChange`, `User#record_level_changes` | No | No change |
| `CompetencyGate` growth | **Yes.** `fixed_window` reads the latest N results pooled across `@fixed_kinds`, a constant for all history | As built in #411: each `Day` carries its row's recorded pair (`Day#daily`), and a result is stored in the growth runs only when its kind was daily that day. The windows read the latest N stored results. They hold the same results tagging every entry would, except that a kind's later optional results never push its earlier daily ones out of `GROWTH_MEMORY`, so they are a superset of tagging. The fold stays pure, still runs forward over every stamped day, and a swap neither erases an earned size nor reclassifies past days. Re-reading all history with today's pair would quietly change sizes users have already earned |
| `CompetencyGate::Evidence#optional_state` | **Yes.** `section_keys - @fixed_kinds` | Uses the row's daily kinds |
| `CompetencyGate` brake | No. It reads every kind | No change |

**Graduation**, when it is built:

- **"Both daily kinds meet the step-up rule"** reads `DailyKinds.for(user)`,
  the current pair, and applies `LevelSuggestion`'s per-kind step-up test to
  each.
- **Rubric breadth** reads `ReviewedSectionResults` across every kind on
  record, with no daily filter.
- **A newly swapped-in kind with too few results** fails the pair test until it
  earns them. That follows from "current pair", and graduation's card should
  say why.

The isolation boundaries still hold. Generation, review, the judges,
`ConceptMastery` and `KindDifficulty` read the daily pair (it is plan state,
like weights), but never track or suggestion state. `DailyKinds` reads neither,
and `level_suggestion_isolation_spec` gains `DailyKinds` and
`DailyKindSwap` to its list of readers that must stay clean of them.

## 6. Rotation and the gate

**Swapped out:**

- **Code review or design comparison** becomes a single-kind optional group,
  like `pattern`. It competes on staleness with the other groups and is never
  rolled within its group.
- **A third or fourth** rejoins its group. `SectionRotation.eligible`, weights,
  exclusion and the starvation drain apply to it again, with no reset. Its
  staleness comes from `recent_exercise_history`, which already records it
  under its key.

**Swapped in:** the kind leaves its optional group for as long as it is daily,
so its siblings rotate without it. Its weight and exclusion are stored but
ignored (section 2).

**Simulated waits.** A port of `SectionRotation.for` and
`WeightedRoll.pick`, copied line for line from main at `abf0892`, was run
with the layout from section 2 and D1 (a). Every reachable pair was simulated: 42 of
them, the 45 pairs of ten kinds minus the three pairs of two fourths. Each
pair ran at a fixed day size, 3,000 days per run (the first 60 discarded),
over five seeds.

The model has no exclusions, default weights and every day a weekday. It has
no retention-driven coverage, and for counts 3 and 4 no coverage exception at
all. The two-section rows ran one pair per group, because the coverage gap
rule there is deterministic and depends only on how many optional kinds the
pair leaves. "Wait" is the number of days between two appearances of a kind.
`spec/services/section_rotation_simulation_spec.rb` (#408) repeats the 3- and
4-section check on the real `SectionRotation`, over 160 days with one seed
instead of 3,000 days over five seeds. It pins the bound for every pair, not
these exact figures.

| Day size | Pairs | Longest wait of any optional kind | Comment |
|---|---|---|---|
| 4 | 21 pairs, 8 optional kinds (no fourth in the pair) | 11 days | Averaged over a pair's kinds, the longest wait is 8.8 to 10.6 days |
| 4 | 21 pairs, 6 optional kinds (a fourth in the pair) | 10-11 days | Pairs of a third and a fourth give 10, all others 11; averaged per pair, 6.5 to 8.0 days |
| 3 | all 42 | 11 days, for every optional kind of every pair | One optional section a day for 6-8 kinds, so the starvation drain is what moves most kinds |
| 2 (Automatic) | 21 pairs with 8 optional kinds | 40 weekdays per kind | Only the coverage exception adds a section, once per 5 weekdays at most, picking the kind unseen longest past `GAP_WEEKDAYS` |
| 2 (Automatic) | 21 pairs with 6 optional kinds | 30 weekdays per kind | Same rule, fewer kinds |
| any | a pair holding a fourth | its two siblings: never | D1 (a); only a swap brings one back |

- **No day size of 3 or 4 makes a kind wait longer than `STARVATION_LIMIT`
  implies.** A kind becomes starved once it has gone 10 days unseen and is
  drained on the next day its group is drawn, so 11 days is the bound, and
  every reachable pair stays within it. The default pair's figures match the
  other pairs', so swapping doesn't make rotation less fair at these sizes.
- **At 2 sections the rotation draws nothing,** so `STARVATION_LIMIT` never
  applies and every optional kind waits on the coverage exception. That is
  main's behaviour today: the default pair also gives 40 weekdays.
- **One result looks wrong for the product, and nothing here tunes it
  away.** On a two-section day, a kind the user swaps *out* comes
  back about once every 40 weekdays (8 weeks), and once every 30 (6 weeks) if
  the new pair holds a fourth. A junior on two sections who swaps code review
  for pattern will see code review roughly every two months. That follows from
  "the swapped-out kind returns to the optional pool": at two sections the
  optional pool is nearly empty. The picker should say so when the user's
  current day size is 2 (copy in section 7). Changing `GAP_WEEKDAYS` or
  `CAP_WEEKDAYS` would change coverage for every account, so it is a separate
  decision.

**The gate unlocks a size, never a kind.** `CompetencyGate::Plan` is
`(count, reason, evidence)`. `locked_section_kinds` locks a kind's
difficulty, not its availability, and exclusion is the user's own choice. So
"swap to a kind the gate hasn't unlocked" is not a state that exists. Any
kind may be swapped in at any level, which matches "no special case for
juniors".

Two edges carry over from today's rules:

- **A fixed Daily sections setting of 2** gives a day of only the daily kinds,
  whatever they are, so the Setup hint names the user's pair.
- **The coverage exception** still adds an optional kind to a two-section
  Automatic day, now from the user's optional groups. It never adds one to a
  fixed setting of 2 (`CoverageException.applies_to_day?` requires
  `fixed.nil?`), so under that setting a swapped-out kind does not come back
  at all. It also never adds a kind the user excluded (section 2), so an
  excluded swapped-out kind does not come back on a two-section day either.

**Gate growth at two sections is out of scope.** An account whose pair holds
a kind the user keeps finding hard is held at two sections. The same is true
on main today for an account that keeps finding code review or design
comparison hard. Swapping doesn't cause it. It is written up, with its
arithmetic and the exits that already exist, in
`docs/superpowers/specs/2026-10-16-two-section-gate-hold-note.md`, and
recorded there as a product question to decide later. The spec that pins the
current behaviour landed in #411 (`competency_gate_daily_pairs_spec`).

## 7. UI

**Placement.**

- **The control can't go in the card's `<summary>`.** `_section.html.erb:7`
  forbids a control inside the summary.
- **It goes in a row directly after the `kind_about` disclosure,** on the first
  `DailyKinds::COUNT` cards only, in both the answer form and the submitted
  dashboard. It behaves the same on both, since a swap never touches the set
  on screen.
- **History never shows it.**

**Markup.**

- **The trigger** is `<button type="button" aria-expanded aria-controls>`,
  labelled "Swap Code review". The pattern matches the duck thread toggle.
  `type="button"` matters because the card sits inside `#gym-form`, where a
  default button would submit the day.
- **The picker** is a `<fieldset>` with a `<legend>` ("Choose the kind for this
  daily section") and one radio per kind. Each label holds the kind's name,
  and the `SectionKindGuide` summary and example are tied to the radio with
  `aria-describedby`. The guide body is extracted from `responses/_kind_about`
  into a partial both use, so #391's text has one home.
- **The radios carry `form="daily-kind-swap"`,** pointing at an empty form
  outside `#gym-form`. Otherwise they would post with the day's answers.
  Their `change` still bubbles to `answer-form#change`, which ignores anything
  outside `[data-field]`.
- **A `daily-kind-swap` Stimulus controller** posts through
  `CodeGymRequest.send` and shows the server's reply. The page holds no copy
  of any rule in this spec: which options are disabled, every consequence
  sentence and the reply sentence all come from the server.

**Picker states.**

- **Options:**
  - the current kind is checked and marked "Now";
  - the other daily kind is disabled, with "Already a daily section";
  - while the other daily kind is a fourth, the two remaining fourths are
    disabled, with "Only one of Plan review, Ambiguity hunt and Pseudocode to
    code can be a daily section." The names come from `ExerciseSection.fourths`;
  - every other kind is available.
- **A line above the options,** always: "Your current set keeps its sections.
  This starts with your next set." When the account is paused, the line adds
  "Generation is paused, so that's the next set you generate or the first one
  after you resume."
- **Consequences, shown before Confirm.** Each sentence below is rendered by
  the server into the option it applies to, tied to that radio with
  `aria-describedby` alongside the guide text, and repeated as the confirm
  sentence when that option is selected. The browser decides none of them.
  - *Choosing a fourth* (D1), naming its two siblings: "Ambiguity hunt and
    Pseudocode to code won't appear on their own while Plan review is a daily
    section. Swap one of them in to get it back."
  - *Choosing a fourth*, for the shared concept: "Your two daily sections will
    no longer look at the same idea from different sides on the same day."
    - This wording is deliberate. It is the dashboard's existing
      `dashboard.shared_concept` phrasing, and it says nothing about why the
      sections share a concept, since that would expose the mastery tier
      (`shared-concept-on-a-real-struggle.md`).
    - It is shown only for pairs holding a fourth. Those are the pairs where
      `SharedConcept` can never apply; other pairs may share less often, but
      not never.
  - *A kind with a stored weight* other than the default: "You set Challenge to
    appear more often in Exercise mix. That setting does nothing while
    Challenge is a daily section, and applies again if you swap it out." The
    sentence uses "less often" for a weight below 1.
  - *A kind the user excluded*: "You turned Challenge off in Exercise mix. As a
    daily section it will be in every set anyway. The setting applies again if
    you swap it out."
  - *The outgoing kind, at two sections.* This is the strongest consequence.
    It is shown as a visible warning paragraph directly above Confirm, not
    only as option description text, and Confirm points at it with
    `aria-describedby`. Its wording depends on why the day has two sections:
    - **The Daily sections setting is fixed at 2:** "Your Daily sections
      setting is 2, so after this swap Code review won't appear at all. Swap
      it back, or raise the setting in Setup, to see it again." This is
      exact, because coverage never runs on a fixed setting.
    - **Automatic, and today's planned size is 2** (the row's
      `plan_notes["size"]`): "Your sets have two sections right now, so after
      this swap Code review will appear about once every 8 weeks, as an extra
      section. Swap it back to have it every day."
      - The figure is computed from `CoverageException::GAP_WEEKDAYS`,
        `CAP_WEEKDAYS` and the number of optional kinds the new pair leaves
        that the user has not excluded, since coverage never adds an
        excluded kind. It is rounded to whole weeks and isn't a stored
        number.
      - **The outgoing kind is excluded in Exercise mix:** coverage will
        never add it, so the warning reads: "You turned Code review off in
        Exercise mix, so after this swap it won't appear at all. Swap it
        back, or turn it on again, to see it."
      - A second sentence follows: "Your two daily sections are also what
        decides when your sets grow." It states that the pair feeds the
        gate, without exposing any rating or tier.
    - **Three or more sections:** no warning. Section 6's simulation puts
      every optional kind within 11 days there.
- **Confirming:** Confirm stays disabled until a different kind is picked.
- **Saving:** both buttons are disabled and a polite live region says
  "Saving…".
- **Saved:** the reply carries the sentence from section 3. The picker
  closes, the sentence is announced, and focus returns to the trigger. When
  regeneration is offered and nothing is submitted (section 3), the "Want it
  in today's set?" line appears under the sentence, cost included, as a link
  to the existing "Generate new set" button.
- **Error:** the reply comes from `render_json_error`, the message shows in the
  save-status banner, the picker stays open and focus stays on Confirm.

**Keyboard and VoiceOver.**

- Tab reaches the trigger, and Enter or Space opens the picker. Focus moves to
  the checked radio, the arrow keys move between radios (native behaviour),
  and Tab reaches Confirm and Cancel.
- Escape or Cancel closes the picker, sets `aria-expanded="false"` and returns
  focus to the trigger, as `nav_menu_controller.js` does.
- VoiceOver reads the trigger's state, the legend, the "next set" line, each
  option's name with its guide text and consequences as the description, and
  the disabled reasons. The reply is announced through the live region.
- A system spec covers keyboard open, arrow, confirm, Escape and focus return,
  plus one VoiceOver-relevant check that the radios carry `aria-describedby`
  pointing at the guide text.

**Discoverability.** Nothing on main would tell a new account that the swap
exists. Two small additions, both static copy with no new state:

- **One line on the welcome page,** under the track buttons, after
  `welcome.note`, in a new `welcome.daily_sections` key: "Every set starts
  with two daily sections, Code review and Design comparison. You can swap
  either one for another kind from its card." The names come from
  `DailyKinds::DEFAULT`.
- **A first-time hint on the first daily card's swap row,** answer form only:
  "New: you can swap this daily section for another kind." It shows while the
  account has no `daily_kind_swaps` row and fewer than 5 submitted days. Both
  are existing reads, so nothing is stored to dismiss it. After that the
  trigger's own label carries the feature.

**Exercise mix.** "In every set" lists the user's daily kinds with their
difficulty controls only. A kind that is daily drops out of its group's
weight and exclusion rows. `code_review` and `design_comparison`, when not
daily, show as single-kind groups with difficulty only, like `pattern`. Setup
does not get a swap control; that stays on the cards.

**Snapshots that change.**

- **Page snapshots:**
  - `dashboard_unsubmitted.html` gains the control and the first-time hint on
    the `code_review` card. The fixture account has no swaps and at most one
    submitted day.
  - `dashboard_submitted.html` gains the control only.
  - The fixture day is code review, pattern and challenge, so only one card
    is daily and the fixture shows the default-pair markup. Add a fixture
    with a swapped pair to the same spec.
  - `setup.html` should not change for a default account. If it does, that is
    a regression to investigate, not a rebaseline.
  - The welcome page has no page snapshot, so its line is covered by a
    request spec and `spec/system/welcome_spec.rb`.
- **Request snapshots:** none change, since a swap makes no provider call.
- **Prompt snapshots:** PR 1 and PR 1b leave every existing file
  byte-identical, which is their proof that a default account is untouched.
  #415 is the one planned rewrite of all 263 files, to name each section by
  its kind. PR 2 adds new shapes: a full prompt for a non-default pair, for
  example `pattern` + `architecture`, and `code_review` + `plan_review` for a
  pair holding a fourth.

## 8. Events

Swaps are logged for analysis in a table of their own, shaped like
`level_suggestion_events`. Each row is written once, in the same user-row
lock as the pair:

```
daily_kind_swaps
  user_id        bigint   not null, indexed
  place          integer  not null   # 0-based index into the daily list
  from_kind      string   not null
  to_kind        string   not null
  today_section  string   not null   # unanswered | answered | submitted | not_in_set | no_set
  planned_size   integer             # today's set's plan_notes["size"]; null when no_set
  size_setting   integer             # users.daily_section_count at the swap; null = Automatic
  created_at     datetime not null
```

- **The old "tomorrow" enum is gone.** Every swap now has the one effect,
  "starts with your next set", so a column naming that effect would hold a
  single value. The in-place design's `today` (`replacing | tomorrow`),
  `reason` and `outcome` columns are dropped (the in-place alternative has them).
- **`today_section` records the state of the outgoing section in today's set
  when the swap is saved.** It answers the question the scope decision left
  open: how often an in-place swap would have replaced something.
  `unanswered` on an unsubmitted set is the case in-place would have
  changed. It is read through `DailyResponse#answered?` and `#submitted?`,
  the existing authorities.
- **`not_in_set`** is recorded when today's set does not hold the outgoing
  kind, as after an earlier swap of the same place or a judge-dropped daily
  section. It is checked before the answer state, so such a swap never counts
  as `unanswered`. Built in PR 2; `docs/decisions/daily-kinds.md` ("The swap")
  is the record.
- **`no_set`** is recorded when the user has no set for today: a weekend
  without "Generate anyway", or a paused account with nothing held.
  - The control lives on a card, so this mostly comes from a page left open
    across midnight. A dashboard loaded Friday evening can post a swap on
    Saturday morning.
  - The server reads today's set when it saves, never the set the page was
    showing, so that swap records `no_set` and doesn't count as evidence that
    someone wanted today's section replaced.
  - Without the value, those rows would be null or would read as
    `unanswered`.
- **`planned_size` and `size_setting` let the table answer "do people swap
  while on two sections?"**
  - `planned_size` copies today's set's `plan_notes["size"]`, the count the
    plan chose before any coverage addition.
  - `size_setting` copies `users.daily_section_count`, so a fixed 2 can be
    told from an Automatic 2. That matters, because under a fixed 2 the
    swapped-out kind never comes back.
- **Copied, not linked.** The other way would be a `daily_exercise_id`
  foreign key that reads the size from the row. The design copies, for
  these reasons:
  - **Point in time.** A link reads the row as it is now. A regeneration
    later the same day rewrites `plan_notes`, including `size`, and the
    setting can change at any time. The question is what the user was on
    when they swapped, and only a copy keeps that.
  - **It covers `no_set`,** where there is no row to link.
  - **It matches the table it is modelled on.** `level_suggestion_events`
    copies its evidence (`window_size`, `favourable`, `too_hard_latest3`)
    rather than linking to results.
  - **No foreign key** to keep consistent when exercises are deleted with an
    account.
  - The cost is two integer columns, and losing anything else on the row,
    such as the pair the set was generated with. If a later question needs
    that, a link can be added then.
- **A refused request** (invalid kind, a second fourth, stale page) writes
  nothing.
- **Demand for "apply now"** is measurable without another column: a swap
  row followed by a regeneration of the same set (`regenerated_at` after the
  row's `created_at`, same date).
- **Validations** follow `LevelSuggestionEvent`: kinds in
  `ExerciseSection.keys`, `today_section` with an `inclusion` check,
  `planned_size` absent for `no_set`, and `size_setting` in
  `User::DAILY_SECTION_COUNTS` when present. `planned_size` may also be null
  on a set: a held set planned before `plan_notes` recorded a size has none,
  and inferring one would be wrong (`docs/decisions/daily-kinds.md`).

## Decisions

- **Scope, decided 2026-10-16:** the swap only saves the pair and starts with
  the next set. The in-place design is in its own file, kept so nothing is lost and
  so it can be built on top later without rework.
- **D1, decided: (a), at most one fourth among the daily kinds.** `DailyPlan`
  runs a separate one-concept track for exactly one fourth kind
  (`fourth_track`, `FOURTH_SLOT_CAPACITY`). While a fourth is daily, the
  optional `fourth` group sits out, and coverage can't add a sibling either
  (section 2). Its two siblings then appear only by swapping, and the pair
  never shares a concept. The picker states both before Confirm (section 7).
  Two daily thirds are fine.
- **D2 to D4 applied only to the in-place swap** (generating while paused, the
  replacement limit, judging the replacement) and are moot here. The D4
  decision that regeneration should be judged still stands on its own; it is
  PR 4 below.
- **The two-section gate hold** is out of scope, and is recorded as a product
  question in its own note (section 6).
- **Recorded pairs, decided 2026-10-16:** no backfill; the default-pair
  fallback covers only rows missing the key, and the write side guarantees
  the key (section 2, `docs/decisions/daily-kinds.md`).
- **Coverage and exclusions, decided 2026-10-16:** coverage keeps an
  exclusion final and adds nothing when every candidate is excluded, unlike
  rotation, on purpose (`docs/decisions/coverage-exception.md`).

## PR order

| Order | PR | What it holds |
|---|---|---|
| 1 | **A. Derive the regeneration claim window** (#406, merged) | A bug on main, independent of this feature (below). It can merge first and on its own |
| 2 | **0. Schema** (#407, merged) | `users.daily_section_kinds` (`jsonb`, default `[]`, not null) and `daily_kind_swaps` with the columns in section 8. Nothing reads either. It ships a release ahead, because the worker's pre-deploy waits for a schema, not for pending migrations (`tracks.md`). It must not share a release with the `learning_track` column drop |
| 3 | **1. Per-user layout, no visible change** (#408) | Covers `DailyKinds` (with its sparse default and on-read normalization), `ExerciseSection.layout(daily:)`, `plan_notes["daily_kinds"]`, row-aware `resolved_keys`, every reader in section 2, `judge_retries` moving onto the plan, text from the pair, Setup's groups and the validations. It also covers the `FLOOR == DailyKinds::COUNT` spec, the grep spec for `ExerciseSection.slots` / `.fixed`, and the rotation simulation spec, plus the write-side guarantee for `plan_notes["daily_kinds"]` (section 2). `CompetencyGate` reads `DailyKinds::DEFAULT`, which is today's pair. A default account stays byte-identical, and the existing prompt, page and request snapshots prove it with no update. Docs: `generation.md`, `design-comparison-the-second-fixed-section.md`, `planning.md`, `coverage-exception.md`, `shared-concept-on-a-real-struggle.md`, `level-suggestions.md:37-42`, `request-flow.md:37`, `patterns.md:55`, `file-map.md`, and a new `docs/decisions/daily-kinds.md` with its entry in `planning.md` |
| 4 | **1b. Per-day pairs in `CompetencyGate`** (#411) | `Day` carries the row's recorded pair, only daily results are stored in the growth runs, and `Evidence#optional_state` uses the row's pair (section 5). Nothing can swap yet, so every stored day holds the default pair, and the interim state between PR 1 and PR 1b is main's behaviour. Its specs: **before and after,** a replay of a synthetic fixture (`spec/fixtures/competency_gate/default_pair_histories.json`, eight seeded 50-day histories that grow, brake and hold, recorded from the gate before per-day pairs; not shaped like production) gives identical plans; **a changing pair,** a hand-built history whose pair changes partway neither reclassifies earlier days nor resets an earned size; **the two-section hold,** the spec from the separate note, pinning today's behaviour. Docs: `competency-gate.md` |
| 4a | **#413. Reinforcement only where today can host it** (not in the original order) | `User#concepts_needing_reinforcement(hostable:)` filters history entries as well as drills, through `DailyPlan.host_test`. It changes default accounts: a reinforcement concept no section today can tag waits for a day that can. Docs: `personalization-loop.md`, `drills.md` |
| 4b | **#415. Name prompt sections by kind** (not in the original order) | Every prompt names a section by its JSON key instead of its position, the fourth-track lines render only when the fourth kind is requested, and `generation_prompt_section_names_spec` scans the snapshots and all Ruby under `app/` and `lib/`. Rewrites all 263 prompt snapshots. Docs: `docs/decisions/kind-named-prompt-sections.md` |
| 5 | **2. The swap, server side** | **Preconditions:** #415 merged; the two lines that assume `code_review` is in the day (`DesignComparison`'s "the same as the code review's" and `SecurityReview`'s "the same bar as code_review's snippet") gated on `code_review` being planned or reworded to stand alone; and a spec that renders the prompt for every reachable pair and asserts each quoted section key it names is in that prompt's schema. Covers `PATCH /daily_kinds/:place` (`DailyKindsController#update`), the `DailyKindSwap` outcome object (`saved` or a refusal reason), the save under the user-row lock with the version bump, the event row with `today_section`, and the reply sentence from section 3. The request spec keeps one example per outcome. It also keeps a weight or exclusion stored on a kind that becomes daily: the Exercise mix save merges stored entries for daily kinds back in, and the `*_name_rotatable_kinds` validations check only the entries a save adds or changes |
| 6 | **3. The card control** | Covers the swap row and picker partial, the extracted guide partial, the `daily-kind-swap` controller, the consequence sentences, the "next set" line and the "Want it today?" line, the welcome line, the first-time hint, the page snapshots and the system specs |
| 7 | **4. Judged regeneration (separate, from D4)** | `RegenerateExerciseJob` moves to `generate_judged_exercise`. It needs its own deadline, because it no longer inherits one from an in-place swap. The in-place alternative's PR 4 entry has the derivation: `REGENERATION_DEADLINE` of 1,187 s from the claim, with the window raised to match and late sections dropped while kept ones land. It matters more now that regeneration is the "apply now" path. It can follow at any point after PR A |

PR 2 and PR 3 could merge into one, since PR 2 is now small. Keeping them
apart still lets the server rules be reviewed without markup.

### PR A: derive the regeneration claim window

- **The bug.** `DailyExercise::REGENERATION_STALE_AFTER` is 6 minutes, and its
  comment says it must exceed `AiService::GENERATION_READ_TIMEOUT` (300 s)
  plus job pickup.
  - The single-stage draft that `RegenerateExerciseJob` makes retries a 429
    or 5xx after a full read, so by the code's own formula its worst case is
    `worst_case_call_seconds(300)` = 946 s.
  - Once the claim goes stale mid-call, `#show` and `#status` stop reporting
    "pending" and the page reverts to the old set while the job still runs.
  - A second `/regenerate` can take the stale claim, and the first job then
    finds a different token and throws its paid result away.
  - A job that lands after the page reverted destroys the response the user
    went back to, since only `replace_blocker` stops it.
  - None of this involves the swap.
- **The change.** `REGENERATION_STALE_AFTER =
  AiService.worst_case_call_seconds(AiService::GENERATION_READ_TIMEOUT) +
  JOB_PICKUP_MARGIN`, with `JOB_PICKUP_MARGIN` at 60 s, the margin the 6-minute
  value already assumed (360 s − 300 s). That gives 1,006 s, about 17 minutes.
  - The comment changes to say the window is derived from the draft's worst
    case.
  - The generating poller already sizes its attempts from
    `[JUDGED_GENERATION_BUDGET, REGENERATION_STALE_AFTER].max / 3 + 1`, so it
    needs no change.
- **Specs.**
  - `REGENERATION_STALE_AFTER` is at least the draft's worst case plus the
    pickup margin.
  - A claim taken 7 minutes ago is still fresh, so `regenerating?`, `#status`
    and `claim_regenerating!` all hold. Today it is stale.
  - A claim older than the window is stale and can be retaken.
- **Cost.** A worker that crashes mid-call now holds the claim for about 17
  minutes instead of 6. The dashboard shows the generating page, then its
  existing slow hint, and `/regenerate` refuses until the claim goes stale.
  The PR says so.
- **Order.** First. It touches nothing the swap touches, and it fixes live
  behaviour, so there is no reason to wait. PR 4 raises the window again when
  regeneration becomes judged.

## Risks

- **Stored days must resolve with their own pair.** A miss in any reader that
  still uses the global layout would silently drop a section from a stored
  day with two thirds. PR 1 adds a spec that greps `app/` for
  `ExerciseSection.slots` / `.fixed` outside the layout's own file, in the
  style of `trial_isolation_spec`.
- **Gate behaviour on old data.** Reading each day's pair must give exactly
  today's sizes for every account that never swapped. PR 1b (#411) checks it
  with the fixture replay.
- **A swapped-out kind nearly disappears on two-section days,** about once
  every 6-8 weeks on Automatic and never on a fixed setting of 2 (section 6).
  The picker says so before Confirm. Changing coverage would change it for
  everyone, so that is a separate decision.
- **A swap feels slow to land.** The new pair can be days away for a paused
  account or a held set. The "next set" copy says so, and regeneration is
  the documented way to apply it now.
- **Comment budget.** `exercise_section.rb` (279 lines) and `daily_plan.rb`
  are near their limits. The layout may need its own class
  (`ExerciseSection::Layout`) to stay under 300 lines and 5 comments.

## Verification plan

- Each PR runs the unit suite
  (`bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`). PR 1 runs it
  in full, since it touches shared authorities (`ExerciseSection`,
  `DailyPlan`, `ProblemSetIngest`).
- `spec/system` runs once before each PR opens; PR 3 adds the keyboard and
  focus specs.
- `bundle exec rubocop` and `bin/comment-check`.
- Snapshots: PR 1 and PR 1b must pass with **no** snapshot update. #415 is
  the one planned rewrite of every prompt snapshot. PR 3
  updates only the page snapshots named in section 7, and each diff is read
  before committing. No request snapshot changes in any PR but PR 4.
- Isolation specs: `level_suggestion_isolation_spec` gains `DailyKinds` and
  `DailyKindSwap`, and `section_kind_guide_spec` still finds nothing under
  `app/services` or `app/jobs` reading `SectionKindGuide`.
- **Which-set specs** for PR 2, one per row of section 3's table:
  - a swap saved after today's set exists leaves that set's `problem_set` and
    `plan_notes` untouched, and the next generated set uses the new pair;
  - a carried-forward held set keeps its pair, and the set generated after it
    is submitted uses the new one;
  - while paused, no set is generated until the user asks, and that set uses
    the new pair;
  - a regeneration after a swap uses the new pair.
- The rotation simulation spec (PR 1) runs section 6's check on the real
  `SectionRotation`, over 160 days with one seed. It asserts the 11-day bound
  at sizes 3 and 4 for every reachable pair, and that a daily fourth's
  siblings never appear. If a change breaks the bound, that is a decision to make, not a
  constant to raise.
- The `critical-reviewer` agent runs on each PR before it leaves draft, with
  this spec as its input.

## The in-place alternative

The design considered and not chosen is in
`2026-10-16-daily-kind-swap-in-place-alternative.md`.
