# Swap which kinds fill the daily places

Status: proposed, not implemented. Waiting on the open decisions at the end.
Date: 2026-10-16. Checked against `origin/main` at `abf0892` (#404).

## Goal

Every account has a fixed number of daily places, two today, and each holds
one section kind. Each daily card gets a swap control. A swap:

- saves the chosen kind as that place's kind from then on;
- generates a new section of that kind for today right away, when today's
  outgoing section is still unanswered;
- returns the swapped-out kind to the optional pool, with its past results
  kept and still counted.

Any level can swap. Swaps carry no special case for juniors, and the user
pays nothing for them. The picker reuses the kind guides from #391.

## Where the code disagrees with the brief

Each point below is something the brief assumes that main does not match.
The design works with what is on main and does not work around these points.

| Brief says | Main says | Effect on this design |
|---|---|---|
| "Juniors default to code review and design comparison" | Every account gets them, at every level. `ExerciseSection.fixed` is `all.select(&:fixed?)`, and only `CodeReview` and `DesignComparison` return `true` (`app/models/exercise_section/code_review.rb:10`, `design_comparison.rb:38`). No rule reads the level | The default pair stays level-independent. Nothing to build for juniors |
| PR 1 of the tracks plan may not have merged and may still write presets | It merged. #398 (`f0c5c6a`) removed the junior preset and "Leave the track". `docs/decisions/tracks.md`: "No preset targets are written". #403 stopped reading `users.learning_track`, and the column drop is the only step left | No conflict and no reason to wait. The column drop touches `users`, so the swap's migration should not ship in the same release as that drop. That is a deploy-order note, not a dependency |
| "Adding other kinds by hand is a separate, existing action" | No such action exists. No controller, route or job adds a kind to today's set or to the plan. The nearest controls all change future plans only: Exercise mix weights and exclusions, the Daily sections count, drills (which move a concept, never a kind), and the automatic coverage exception | This design keeps the code and the UI open for that action without building it. The swap lives in `DailyKinds` and `DailyKindSwap`, so an "add a kind" action would get its own name and endpoint |
| "The graduation rubric" is planned work to align with | No graduation rubric, "breadth" rule or "both daily kinds" rule is written anywhere in `docs/`, `.claude/` or git history. Graduation shows up only in passing: `tracks.md` says it will reuse `TrackChange` and follow the suggestions switch | Section 5 states what graduation should read. There is nothing on main to change |
| Daily places will grow "as the section count grows" | Nothing on main plans more than two. `SectionCount::FLOOR = 2` equals `ExerciseSection.fixed.size` by convention only, and `CompetencyGate::FLOOR`, `User::DAILY_SECTION_COUNTS` and the Setup hint ("%{lowest} gives you only %{fixed_sections}") all depend on that | The count is derived, never stored, and a spec asserts `FLOOR == DailyKinds::COUNT` (section 2) |
| A daily place can hold any kind | `ExerciseSection.slots` groups the kinds, and a group resolves to **one** kind per day: `third` covers architecture, security review, challenge and Parsons, and `fourth` covers plan review, ambiguity hunt and pseudocode to code. `resolved_keys` keeps the first present key in each group | If the stored pair simply replaced `fixed?`, pinning architecture as daily would keep the other three thirds off every day. Worse, a stored row holding two thirds would lose one from `active_section_keys`. Section 2 introduces a per-user layout to fix this, and the decision on fourth kinds is open (D1) |
| Swaps are "free and unlimited" | Main has no cap on daily generations for own-key accounts. `/regenerate` is once a day, `/generate` is 3 an hour, and trial accounts count every call against the invite's daily cap | Choosing a kind stays unlimited. Generating today's replacement right away is rate-limited per hour, and a refused generation still saves the choice (section 4, D3) |

## 1. How the daily kinds are decided today

There is no single place that holds "this user's daily kinds". It is a
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

**Recommendation:** build now. Nothing the tracks work still has to do touches
these call sites.

## 2. Storage, layout and the place count

### The stored choice

- **Column.** Add `users.daily_section_kinds`, `jsonb`, default `[]`, not null.
- **Empty means the default pair.** Storage is sparse, like the kind
  preferences, so an untouched account plans, prompts and renders exactly as it
  does today.
- **Order is the place.** Index 0 is the first daily card and index 1 the second.
- **Validation runs on write.** The list must be empty, or exactly
  `DailyKinds::COUNT` distinct keys from `ExerciseSection.keys` that also pass
  the rule chosen under D1.

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
it.

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
- **`CoverageException`**: the optional kinds are those outside today's daily
  pair, and the "two-section day" test is `count <= daily.size`.
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
  layout, so a daily kind can't be weighted or excluded. A weight or exclusion
  already stored on a kind that becomes daily stays stored and is ignored
  while the kind is daily, then applies again when it goes back to the pool.
  That keeps storage sparse and makes a swap reversible.

`DailyPlan::Result` gains `daily_kinds`. The `pattern`/`third`/`fourth`
fields stay, because `GenerationPrompt` and the fourth track read them.

### When the place count changes

`DailyKinds.for` normalizes on read, so a stored list from another release
always fits:

- **Count grew:** the stored kinds keep their places, and the new place gets the
  first `DEFAULT` kind not already held.
- **Count shrank:** the list is cut from the end, so the first places keep their
  kinds.
- **Unknown key** (a kind removed from the registry): that place falls back the
  same way as a grown count.

A user's pair is never rewritten in the database by a count change. The next
swap writes a list of the new length. Two specs pin this: one for the
normalization, and one asserting that `SectionCount::FLOOR`,
`CompetencyGate::FLOOR` and `User::DAILY_SECTION_COUNTS.min` all equal
`DailyKinds::COUNT`. Today they only happen to match.

## 3. What a swap does to today's exercise

A swap always saves the new pair under the user-row lock and bumps
`section_kind_preferences_version`, so an Exercise mix open in another tab gets
the usual 409. What happens to today's row depends on its state:

| Today's state | Effect on today | Why |
|---|---|---|
| No row for today (weekend, paused with nothing held, trial ended) | None. The pair applies from the next generation | Nothing to replace |
| Generating or regenerating (`regenerating_since` fresh, or the first generation queued) | None. The pair applies tomorrow. The card isn't on screen in this state, so this only covers a race | The in-flight plan already chose its kinds |
| Response submitted, reviewing or reviewed | None. The pair applies tomorrow | Submitted work is never replaced (`one-reviewed-response-invariant`) |
| Not submitted, and the outgoing section **answered** (`DailyResponse#answered?`) | None. The pair applies tomorrow | Your choice: finished work is not replaced |
| Not submitted, outgoing section **unanswered**, and the incoming kind is **already in today's set** as an optional section | None, and nothing is generated. The pair applies tomorrow | Generating would duplicate a section the user already has. Promoting the existing section without removing the outgoing one would leave the day's daily places in a state no plan produced |
| Not submitted, outgoing section **unanswered**, incoming kind not in today's set | **Replace in place:** generate one section of the incoming kind, swap the key in `problem_set`, set `plan_notes["daily_kinds"]`, and drop the outgoing key from `answers`, `section_ratings` and `concept_tags` | Matches "generates a new problem right away". Discarding would shrink the day, and keeping both would break the count. An unanswered draft is not evidence (`personalization-loop.md`) |
| A held set carried forward to today | Same as the rows above. It is an ordinary row for today once `carry_held_set_forward!` has moved it, which `DashboardController#show` does before the card renders | One rule for every row dated today |

"Answered" is `DailyResponse#answered?`, the one authority. A typed but
unanswered draft in the outgoing section is discarded, and the confirm text
says so.

### Reuse, and what is new

- **`RegenerateExerciseJob` is not a fit.** It regenerates the whole set,
  destroys the response, runs once a day (`regenerated_at`) and resets
  `generated_at`, which invalidates every draft. A swap must keep the other
  sections' answers.
- **`AiService#retry_section` is the fit for the call itself.** It renders
  `GenerationPrompt#render(only: kind)` and ingests one key, with
  `expected_keys: [kind.key]`. It is private to judged first generation and
  needs a `Draft`. Add a public `AiService#generate_swapped_section(user,
  exercise, kind)`:
  - it builds the plan with `DailyPlan.for(user, language: exercise.language)`
    after the new pair is saved, so the incoming kind's group, reinforcement and
    retention selection come from the normal rules;
  - it renders `only: kind` with no fixed concept and ingests one key with the
    usual stamps (`pitched_at`, `eased`);
  - it shares the prompt/ingest half with `retry_section`, so the one-kind
    shape lives in one place.

  It is single-stage, like regeneration and weekend sets: no judge. That is a
  quality trade-off (D4).
- **Concepts may repeat today's other sections.** The fresh plan doesn't know
  today's other concepts. A known limit, logged and not prevented.
- **`ApiUsage` gets a new purpose, `swap_section`**, so swaps can be counted
  apart from `retry_section` and `generate_exercise`. It adds a `CALL_PROFILES`
  entry (the `retry_section` timeout) and the per-provider routing entries.
  The characterization spec requires one request snapshot per purpose per
  provider.

### Claim and lock order

`SwapSectionJob` runs this sequence. No step nests the user row around the
exercise row; that order exists only in `carry_held_set_forward!`.

1. **Controller, under `current_user.with_lock`:** validate and save the pair,
   bump the version and write the event row. Release the lock.
2. **Controller, under `exercise.with_response_locked`:** check the table above
   (row dated today, not submitted, outgoing section unanswered, incoming kind
   absent, no fresh claim). If the swap goes ahead, take the claim. Release.
3. **Job:** the paid call, outside any lock.
4. **Job, under `exercise.with_response_locked`:** re-check the claim token and
   every condition from step 2. The user may have answered the outgoing
   section or submitted while the call ran.
   - If they all still hold, write `problem_set`, `plan_notes["daily_kinds"]`
     and the response's three maps, then release the claim.
   - If any changed, release the claim and drop the generated section. The
     cost is spent, and the usage row records it.

**The claim reuses `regenerating`** (`regenerating_since`, 6 minutes stale)
instead of adding a column. It is already the lease on "a paid call rewriting
this row's set". `DashboardController#show`/`#status` already show the
generating page and poll while it is fresh, and `RegenerateExerciseJob`
already refuses while it is held, so a swap and a regeneration can't overlap.
The swap does **not** set `regenerated_at` (a swap doesn't use up the day's
regeneration) and does **not** touch `generated_at`, so `draft_scope` and every
other section's draft stay valid. The generating partial gets a swap-specific
hint. This is a deviation from one claim per purpose, and the PR states why.

## 4. Cost control

What main has today:

- **No per-user cap on daily generations for own-key accounts.**
  `ProviderCallLimits` (60 an hour, 300 a day) covers the conversational calls
  only and is skipped for own-key accounts. `/generate` is 3 an hour for
  everyone, and `/regenerate` is once a day.
- **Trial (house-key) accounts** count every call, judges and retries
  included, against `invite_code.daily_request_cap` through
  `TrialAllowance#check_account_cap!`. A refusal raises `TrialAllowanceError`
  and writes no row.
- **`ApiUsage` writes one row per call**, but regeneration logs as
  `generate_exercise`, so it can't be told apart today.

Proposal:

- **Choosing a kind is unlimited.** It saves a row and calls no provider.
- **Generating today's replacement is limited per hour,** with
  `rate_limit to: SWAP_GENERATIONS_PER_HOUR` (proposed 6) on the swap action,
  for every account, the way `/generate` is limited. When the limit is hit,
  the pair is still saved and today is untouched. The reply says: "Saved. You've
  swapped several times in the last hour, so today's section stays as it is and
  the change starts tomorrow." That keeps "swaps are free and unlimited" true
  for the choice, and bounds the spend from a stuck or scripted client.
- **A swap does not count against `/regenerate`'s once a day,** and regenerating
  doesn't use up swaps.
- **On a trial, the swap call counts against the invite's daily cap** like any
  other call. A `TrialAllowanceError` in the job releases the claim and shows
  the existing `provider_failures.trial_allowance_used` text with a new
  `outcomes.swap`: "today's section wasn't replaced; your choice starts
  tomorrow". Other provider failures use the same failure wording path as
  regeneration, under `what-a-person-is-told-when-a-provider-fails`.
- **The new purpose** makes the volume measurable:
  `ApiUsage.where(purpose: "swap_section")`.

Whether the hourly limit should exist at all is D3.

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
| `CompetencyGate` growth | **Yes.** `fixed_window` reads the latest N results pooled across `@fixed_kinds`, a constant for all history | Each `Day` carries that day's daily kinds from `plan_notes`, and `record` tags each entry with whether its kind was daily that day. The growth window is the latest N tagged entries. The fold stays pure, still runs forward over every stamped day, and a swap neither erases an earned size nor reclassifies past days. Re-reading all history with today's pair would quietly change sizes users have already earned |
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

**Staleness changes.** The optional groups grow from three to as many as four,
for example a `pattern` + `architecture` pair leaves `code_review`,
`design_comparison`, `third` and `fourth`. On a two- or three-section day only
zero or one optional section is drawn, so a group can wait longer.
`STARVATION_LIMIT` works within a group, and group choice is by staleness, so
every group still comes round. A simulation spec over 60 days of each
reachable pair will assert the longest wait per kind and state the bound.

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
  Automatic day, now from outside the user's pair.

## 7. UI

**Placement.**

- **The control can't go in the card's `<summary>`.** `_section.html.erb:7`
  forbids a control inside the summary.
- **It goes in a row directly after the `kind_about` disclosure,** on the first
  `DailyKinds::COUNT` cards only, in both the answer form and the submitted
  dashboard.
- **On the submitted dashboard,** the control states that the change starts
  tomorrow before the user confirms.
- **History never shows it.**

**Markup.**

- **The trigger** is `<button type="button" aria-expanded aria-controls>`,
  labelled "Swap Code review". The pattern matches the duck thread toggle.
  `type="button"` matters because the card sits inside `#gym-form`, where a
  default button would submit the day.
- **The picker** is a `<fieldset>` with a `<legend>` ("Choose the kind for this
  daily place") and one radio per kind. Each label holds the kind's name, and
  the `SectionKindGuide` summary and example are tied to the radio with
  `aria-describedby`. The guide body is extracted from `responses/_kind_about`
  into a partial both use, so #391's text has one home.
- **The radios carry `form="daily-kind-swap"`,** pointing at an empty form
  outside `#gym-form`. Otherwise they would post with the day's answers.
  Their `change` still bubbles to `answer-form#change`, which ignores anything
  outside `[data-field]`.
- **A `daily-kind-swap` Stimulus controller** posts through `CodeGymRequest.send`.
  It first waits for the answers queue through `CodeGymSaveStatus.queue`, so
  an in-flight autosave lands before the server checks "answered". The server
  replies with its outcome. The page holds no copy of the table in section 3:
  the outcome and its sentence come from the server.

**Picker states.**

- **Options:**
  - the current kind is checked and marked "Now";
  - the other daily kind is disabled, with "Already a daily place";
  - kinds D1 rules out are disabled, with a reason;
  - a kind already in today's set reads "In today's set. Starts tomorrow";
  - every other kind is available.
- **Confirming** opens the picker without a pre-selection change. Confirm
  stays disabled until a different kind is picked. When today's outgoing
  section has a typed but unanswered draft, the server renders the confirm
  sentence "This replaces today's Code review section and its unsaved draft."
  into the picker.
- **Saving:** both buttons are disabled and a polite live region says
  "Saving…".
- **Replacing:** the reply says `replacing` and the page reloads into the
  generating partial, which polls `/dashboard/status` as it does for a
  regeneration.
- **Saved for tomorrow:** the reply says `tomorrow` with a sentence naming why
  (answered, submitted, already in today's set, or rate-limited). The picker
  closes, the sentence is announced, and focus returns to the trigger.
- **Error:** the reply comes from `render_json_error`, the message shows in the
  save-status banner, the picker stays open and focus stays on Confirm.

**Keyboard and VoiceOver.**

- Tab reaches the trigger, and Enter or Space opens the picker. Focus moves to
  the checked radio, the arrow keys move between radios (native behavior), and
  Tab reaches Confirm and Cancel.
- Escape or Cancel closes the picker, sets `aria-expanded="false"` and returns
  focus to the trigger, as `nav_menu_controller.js` does.
- VoiceOver reads the trigger's state, the legend, each option's name with its
  guide text as the description, and the disabled reasons. The outcome is
  announced through the live region.
- A system spec covers keyboard open, arrow, confirm, Escape and focus return,
  plus one VoiceOver-relevant check that the radios carry `aria-describedby`
  pointing at the guide text.

**Exercise mix.** "In every set" lists the user's daily kinds with their
difficulty controls only. A kind that is daily drops out of its group's
weight and exclusion rows. `code_review` and `design_comparison`, when not
daily, show as single-kind groups with difficulty only, like `pattern`. Setup
does not get a swap control; that stays on the cards.

**Snapshots that change.**

- **Page snapshots:** `dashboard_unsubmitted.html` and `dashboard_submitted.html`
  gain the control on the `code_review` card. The fixture day is code review,
  pattern and challenge, so only one card is daily and the fixture shows the
  default-pair markup. Add a fixture with a swapped pair to the same spec.
  `setup.html` should not change for a default account. If it does, that is a
  regression to investigate, not a rebaseline.
- **Request snapshots:** three new files, `<provider>__swap_section.json`.
- **Prompt snapshots:** every existing file stays byte-identical. New shapes
  are a one-kind swap prompt, and a full prompt for a non-default pair (for
  example `pattern` + `architecture`, plus one holding a fourth if D1 allows
  it).

## 8. Events

Log swaps for analysis in a table of their own, shaped like
`level_suggestion_events`. It records only what was asked and what happened to
today:

```
daily_kind_swaps
  user_id     bigint   not null, indexed
  place       integer  not null   # 0-based index into the daily list
  from_kind   string   not null
  to_kind     string   not null
  today       string   not null   # replacing | tomorrow
  reason      string             # for tomorrow: answered | submitted | in_set | no_set | busy | limited
  created_at  datetime not null
```

- **One row per accepted swap,** written in the same user-row lock as the
  pair. A refused request (invalid kind, stale page) writes nothing.
- **Whether a `replacing` swap actually landed** comes from the job:
  `ApiUsage` holds the call's outcome, and the job logs `[swap_section]
  user= place= outcome=landed|superseded|failed`. No row update means no
  second write path.
- **Validations** follow `LevelSuggestionEvent`: kinds in `ExerciseSection.keys`
  and enums with an `inclusion` check.

## Open decisions

- **D1. Can a fourth kind be daily?** `DailyPlan` runs a separate one-concept
  track for exactly one fourth kind (`fourth_track`, `FOURTH_SLOT_CAPACITY`).
  A daily fourth plus a rotated fourth would mean two fourths in one day,
  which the track can't plan. Options:
  - (a) allow at most one fourth among the daily kinds, and while one is daily
    the optional `fourth` group sits out, so its siblings appear only by
    swapping;
  - (b) forbid fourths as daily kinds for now;
  - (c) generalize the fourth track to a list, a larger refactor that changes
    `DailyPlan::Result` and the prompt.

  **Recommendation: (a).** It keeps the change in the layout and is easy to
  lift later. Two daily thirds are fine under every option.
- **D2. A swap while today's set is held or paused.** This design treats a
  carried-forward row like any other. Pausing stops only generation the user
  didn't ask for, so a swap still generates while paused. Confirm.
- **D3. The hourly limit on in-place generation.** It is proposed at 6, with the
  choice always saved. Alternatives: no limit for own-key accounts, or a daily
  count instead.
- **D4. Judge the swapped section?** Single-stage, as proposed, matches
  regeneration and is one call. Judging adds at least one call and up to the
  daily kinds' two retries, which is closer to first-generation quality for
  the very sections the user cares most about.

## PR split

0. **Schema only.** Add `users.daily_section_kinds` (`jsonb`, default `[]`)
   and `daily_kind_swaps`. Nothing reads either. It ships a release ahead,
   because the worker's pre-deploy waits for a schema, not for pending
   migrations (`tracks.md`). It should not share a release with the
   `learning_track` drop.
1. **Per-user layout, no visible change.** Covers `DailyKinds`, the layout,
   `plan_notes["daily_kinds"]`, row-aware `resolved_keys` and every reader in
   sections 2 and 5, `judge_retries` moving to the plan, text from the pair,
   Setup's groups and the validations. A default account stays byte-identical,
   and the existing prompt, page and request snapshots prove it. Specs set a
   non-default pair directly on the user. Docs and rules updates:
   - `generation.md` and `design-comparison-the-second-fixed-section.md`;
   - `planning.md`, `competency-gate.md`, `coverage-exception.md` and
     `shared-concept-on-a-real-struggle.md`;
   - `level-suggestions.md:37-42`;
   - `request-flow.md:37`, `patterns.md:55` and `file-map.md`;
   - a new `docs/decisions/daily-kinds.md`, with its entry in `planning.md`.
2. **The swap, server side.** Covers `PATCH /daily_kinds/:place`
   (`DailyKindsController#update`), the `DailyKindSwap` outcome object, the
   event row, the `swap_section` purpose, profile, routing and snapshots,
   `AiService#generate_swapped_section` sharing `retry_section`'s one-kind
   half, `SwapSectionJob`, the rate limit and the failure wording. Request
   specs cover one example per outcome.
3. **The card control.** Covers the partial, the `daily-kind-swap`
   controller, the extracted guide partial, the generating hint, the page
   snapshots and the system specs.

PR 2 and PR 3 could merge into one. Keeping them apart lets the server rules
be reviewed without markup in the diff.

## Risks

- **Stored days must resolve with their own pair.** A miss in any reader
  that still uses the global layout would silently drop a section from a
  stored day with two thirds. PR 1 adds a spec that greps `app/` for
  `ExerciseSection.slots`/`.fixed` outside the layout's own file, in the style
  of `trial_isolation_spec`.
- **Gate behavior on old data.** Tagging entries per day must give exactly
  today's sizes for every account that never swapped. Check it with
  `CompetencyGate.plans` over a production-shaped fixture, before and after.
- **Rotation fairness with more optional groups.** Covered by the simulation
  spec. If the longest wait goes past what `STARVATION_LIMIT` implies, that is
  a decision to make, not a constant to raise.
- **Swap quality.** A single-stage section is unjudged (D4), and its concept
  may repeat one of today's other sections.
- **Spend.** An own-key user can swap up to the hourly limit, every hour. The
  `swap_section` purpose makes this visible. Nothing alerts on it.
- **Race with autosave.** The page flushes the answers queue before posting,
  and the job re-checks "answered" under the lock. A section answered mid-call
  keeps the user's work and wastes one call.
- **Comment budget.** `exercise_section.rb` (279 lines) and `daily_plan.rb`
  are near their limits. The layout may need its own class
  (`ExerciseSection::Layout`) to stay under 300 lines and 5 comments.

## Verification plan

- Each PR runs the unit suite
  (`bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`), and PR 1 runs
  it in full, since it touches shared authorities (`ExerciseSection`,
  `DailyPlan`, `ProblemSetIngest`).
- `spec/system` runs once before each PR opens; PR 3 adds the keyboard and
  focus specs.
- `bundle exec rubocop` and `bin/comment-check`.
- Prompt, page and request snapshots: PR 1 must pass with **no** snapshot
  update. PR 2 and PR 3 update only the files named in section 7, and each
  diff is read before committing.
- Isolation specs: `level_suggestion_isolation_spec`, `trial_isolation_spec`
  and `section_kind_guide_spec` (the swap job must not read
  `SectionKindGuide`).
- Lock and claim specs for `SwapSectionJob`: superseded by a regeneration,
  answered mid-call, submitted mid-call, stale claim and provider failure.
- The `critical-reviewer` agent runs on each PR before it leaves draft, with
  this spec as the brief.
- After PR 2 deploys, `ApiUsage.where(purpose: "swap_section")` grouped by
  `failure` is the first week's check.
