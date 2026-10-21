# Daily kinds

`DailyKinds` (`app/models/daily_kinds.rb`) decides which section kinds a
user gets in every set. Before it, "every day holds code review and design
comparison" was a facet on two kinds (`fixed?`) that a dozen readers asked
the registry about. Now the pair is a per-user value, and every reader that
needs it takes it as an argument. A user changes their pair from a daily card's
swap control ("The swap" and "The card's control" below). An account
that never swaps plans and prompts exactly as before.

## What `DailyKinds` owns

- `DailyKinds::DEFAULT` is the registry's default pair, the kinds whose
  `.default_daily?` is true: `code_review` and `design_comparison`, in that
  order. `default_daily?` replaced `fixed?`, and `ExerciseSection.fixed` is
  gone, so there is one answer to "which kinds are daily".
- `DailyKinds::COUNT` is `DEFAULT.size`, so a third default kind raises the
  count with no other edit.
- `DailyKinds.for(user)` reads `users.daily_section_kinds` and returns the
  normalized list of kind classes.
- `DailyKinds.recorded(plan_notes)` reads the pair a stored day was planned
  with.
- `DailyKinds.problems_with(keys)` is the write-time check `User` runs. It
  accepts an empty list, or a list of `COUNT` key strings that `.normalize`
  leaves unchanged. The rules about which pairs are allowed are therefore
  stated once, in `.normalize`, and validation can't drift from them.
- `DailyKinds.place?(n)` says whether `n` names a daily place, and
  `DailyKinds.stored(keys)` gives a pair's stored form, `[]` for the default
  pair. The swap and its event row ask them, so neither restates the range or
  the sparse storage rule.
- `DailyKinds::DEFAULT` reads `ExerciseSection.default_daily`, so the
  registry never depends on `DailyKinds`.

## Storage is sparse

`users.daily_section_kinds` is `jsonb`, default `[]`. An empty list means
the default pair, so an untouched account stores nothing. Order is the
place: index 0 is the first daily section and index 1 the second. A
non-empty list must name exactly `COUNT` distinct known kinds, holding at
most one fourth-slot kind (`User#daily_section_kinds_name_a_full_set`).

## Normalized on read

`DailyKinds.normalize` makes any stored list fit the current registry
without rewriting the row:

- the list is cut to `COUNT`, so the first places keep their kinds;
- a missing place, an unknown key, a repeat, or a second fourth kind falls
  back to the first `DEFAULT` kind not already held.

A user's stored list is never rewritten by a count or registry change; the
next write stores a list of the new length.

## Each day records its pair

`DailyPlan::Result#daily_kinds` holds the pair the plan used, and
`#notes` writes it to `plan_notes["daily_kinds"]` on every plan.
`RegenerateExerciseJob` rewrites it with the rest of the notes. Anything
that later reads a stored day reads that day's pair through
`DailyExercise#daily_kinds` and never recomputes it. A row without the key
was planned before the pair was recorded, when the default pair was the
only one, so `recorded` falls back to `DEFAULT`. A recorded pair is read
exactly as stored and never fitted to today's `COUNT` the way a user's
setting is: if the count or the registry changed later, re-fitting would
reclassify a past day. An unknown key is dropped, and a pair whose every
key is unknown reads as empty rather than as `DEFAULT`, since that row
recorded a pair and the default was not it. An empty pair shares no
concept, so `ExerciseSection.daily_sections_share?` is false for it.

That fallback is for old rows only, and it must never hide a writer that
forgot the key, since a swapped user's day would then be read with the wrong
layout and lose sections. No backfill was run: it would rewrite history and
change no behaviour (decided 2026-10-16). The guarantee is on the write side
instead:

- `DailyPlan::Result#notes` always writes `daily_kinds`.
- `AiService::JudgedSet` requires `plan_notes`, so neither generation path can
  build a result without the plan's notes.
- `spec/models/daily_exercise_plan_notes_spec.rb` lists every file under
  `app/` and `lib/` that writes a problem set, and fails when a new one
  appears. It checks each path with a non-default pair, so the fallback cannot
  make it pass: the cron and on-demand generation job (judged weekday and
  unjudged weekend), `RegenerateExerciseJob`, the held-set carry-forward
  (which moves the row and keeps its own pair) and `PreviewSeed`.

A model validation on create was considered and not added. Specs create
about 259 rows directly without notes, and a factory default filling the key
in would itself mask a forgotten writer. Scripts that build unsaved
single-section rows (`script/model_comparison.rb`,
`script/security_audit/prompt_injection_red_team.rb`) are left as they are,
because a single section resolves the same under any pair.

## The layout

`ExerciseSection.layout(daily:)` replaced the global `ExerciseSection.slots`.
It returns the day's slots in order:

1. each daily kind in a slot of its own, in stored order;
2. `pattern`, `third` and `fourth`, each minus any daily kind;
3. a default kind that is not daily, as a single-kind slot like `pattern`.

Empty slots are dropped. While a fourth-slot kind is daily, the `fourth`
slot is left out entirely, so its siblings never appear unless swapped in
and a day never holds two fourths. For the default pair the layout is
exactly the old `slots`, in the old order, which fixes the prompt's and
the page's section order; the existing prompt, page and request snapshots
pass unchanged.

`ExerciseSection.optional_slots(daily:)` is the layout without the daily
slots. Every reader takes the pair:

- `ExerciseSection.resolved_keys(problem_set, daily:)`, which
  `DailyExercise#active_section_keys` calls with the row's pair. Without it,
  a day with `architecture` daily and `challenge` rotated would show only
  one of them.
- `ProblemSetIngest` (`daily:`) prunes, counts slots and finds a successor
  after an unusable section from the plan's layout.
- `SectionRotation.for(..., daily:)` counts `daily.size` mandatory slots
  and rotates `optional_slots`.
- `CoverageException.for(..., daily:)` picks from `optional_slots`, and a
  two-section day is `count <= DailyKinds::COUNT`.
- `SharedConcept.pick(..., daily:)` shares a concept across the pair. A
  fourth kind cannot tag a language concept, so a pair holding one never
  shares.
- `ExerciseSection.for_plan(daily:, rotation:)` lists the day's kinds;
  `DailyPlan::Result#kinds` is the one call site the generation prompt,
  `ExerciseDraft.call` and `script/forced_concept_drafts.rb` read.
  `slot_kinds` refuses a rotation that names a slot the pair leaves no room
  for.
- `DailyPlan::Result#rotation` holds what the rotation (and any coverage
  addition) chose per optional slot. `#fourth` is the day's fourth kind,
  daily or rotated, since the fourth track plans either the same way.
- The shared-concept prompt line, `DailyExercise#shared_concept_shown?` and
  the dashboard hint name the row's pair; Setup's "In every set" group and
  the Daily sections hint name the user's current pair.

## Judge retries are a plan fact

A rejected section gets `DailyPlan::DAILY_JUDGE_RETRIES` (2) retries when
its kind is one of the plan's daily kinds and `ROTATED_JUDGE_RETRIES` (1)
otherwise (`DailyPlan::Result#judge_retries`). The extra retry follows the
daily place, not the kind, because every set is built around those
sections. `CallProfiles::JUDGED_GENERATION_BUDGET` reads the larger of the two.

## Which kinds count as offered

`ExerciseSection.pickable(daily:)` is the set of kinds a plan can hold for a
pair: the pair plus every kind in its optional slots. `KindPreferences#offered`
removes excluded optional kinds from it through `KindPreferences#eligible`,
the same rule rotation uses: exclusion narrows a slot, and a slot it would
empty keeps every kind, because rotation still fills it. A daily kind counts as offered even
when an exclusion is stored on it, since every set holds it, and a daily
fourth's siblings never count. `LadderCoverage` (which concepts guidance
preparation covers), the Progress page's "not offered" standing and the
level-suggestion card read this answer. For the default pair it is every kind
minus the excluded ones, as before.

## Weights and exclusions on a daily kind

`SectionKindSettings` checks weights and exclusions against the user's
layout, so a weight or exclusion can't be added for a daily kind. Rotation and coverage read only optional slots, so
a weight or exclusion stored on a kind before it became daily is ignored while
it is daily.

The entry is kept across a swap, so swapping a kind back restores its
setting:

- The Exercise mix form posts only the controls on screen. A daily kind has
  no weight row there, and while a fourth kind is daily its two siblings have
  no row at all, so neither their weights and exclusions nor their difficulty
  targets and locks are posted. `ProfileUpdate` passes every save through
  `SectionKindSettings#keep_unrendered`, which merges back the stored weights and
  exclusions for kinds outside `ExerciseSection.rotatable` and the stored
  targets and locks for kinds outside `ExerciseSection.pickable`, the two sets
  Setup renders controls for.
- A Setup page left open while another tab swaps a kind was rendered for the
  old pair. Its next save gets the usual 409, and the reply's
  `layout_changed`, decided by the server from the `layout` the page posts,
  makes the page reload instead of saving with controls missing.
- `SectionKindSettings` checks only the weight and exclusion entries a save
  adds or changes, so a kept entry for a daily kind never refuses a save, and
  a new entry for one still is.

`SectionKindSettings` checks for an emptied slot when the exclusions or the
pair change. A
pair that leaves an optional slot with every kind excluded is refused, and
`DailyKindSwap` names those kinds in its refusal. Without that, rotation would
fall back to the excluded kinds (`KindPreferences#eligible`) and the user's
exclusion would stop holding.

## The swap

`PATCH /daily_kinds/:place` (`DailyKindsController#update`) saves one place of
the pair through `DailyKindSwap`. Under the user-row lock it refuses, in
order:

1. an ended trial (`trial_ended`): it gets no next set, so a reply promising
   one would be false;
2. a place outside `0...COUNT` (`invalid_place`) or an unknown kind
   (`unknown_kind`);
3. a posted `section_kind_preferences_version` that is not the stored one
   (`stale`, answered 409 with the current pair and version);
4. the kind already in that place (`unchanged`), the other daily kind
   (`already_daily`), a second fourth kind (`second_fourth`), or a pair that
   empties an optional slot of everything not excluded (`empties_a_slot`).
   The repeat and second-fourth rules are `DailyKinds.conflict`, the same
   check `normalize` places kinds with, and the emptied slot is
   `KindPreferences#all_excluded?`, the test rotation's fallback reads.

A validation failure the checks above did not foresee, such as a legacy row
whose stored size setting is no longer listed, rolls the save back and is
refused as `invalid`. Every refusal but `stale` is a 422, and none writes
anything. A saved swap stores
the pair (an empty list when it is the default again, so storage stays
sparse), bumps the preferences version through `User`'s `before_save`, so an
Exercise mix open elsewhere gets its usual 409, and writes one
`daily_kind_swaps` row (`DailyKindSwapEvent`). It never touches today's
exercise, its response, a claim or a provider.

The reply sentence comes from the server: "Saved. This starts with your next
set.", with the paused wording while `paused_generation_at` is set, and a
separate `want_it_today` line only while
`DailyExercise#regeneration_offered?` holds and today's response is not
submitted. That method is the regenerate button's three conditions (not
reviewed, not already regenerated, trial not ended); the button reads it too.

`DailyKindSwap.refusal(user, place:, kind:)` answers the pair rules without a
version, for the card's picker to mark the options it can't offer.

The event's `today_section` is checked in this order: `no_set` (no set
today and, for a paused user, no held set waiting to move to today),
`not_in_set` (today's set does not hold the outgoing kind, as after
an earlier swap or a judge drop), `submitted`, then `answered` or
`unanswered` through `DailyResponse#answered?`. A held set that a dashboard
load hasn't yet moved to today counts as the paused user's set. `planned_size` copies that set's
`plan_notes["size"]` and stays null for `no_set`, and also for a held set
planned before `plan_notes` recorded a size. The model is
`DailyKindSwapEvent` on the `daily_kind_swaps` table, since `DailyKindSwap`
is the swap itself.

## The card's control

Each delivered daily card, in the answer form and on the submitted
dashboard, gets an icon button at the right end of its title row that opens
a bottom sheet (`daily_kinds/_swap`). History never shows it. Cards are
matched to places by membership in the day's recorded pair, so a
judge-dropped daily section has no control and no control moves onto a
rotating card. `DailyKindSwap::Picker` builds what each card shows, and
`DailyKindSwap::Consequences` the sentences for each available option; both
are pure reads of server state, and the `daily-kind-swap` Stimulus
controller only shows and hides what they rendered. #421 first shipped an
inline picker under the card's heading; the sheet replaced it in PR 3b
without changing the endpoint, its reply, `DailyKindSwap`, `Picker`'s rules
or `Consequences`.

- The trigger is the first element after the card's `<summary>`, since a
  control inside the summary would be a control inside a control. It sits
  absolutely over the title row (a card holding `.daily-kind-swap` is
  positioned through `:has()`, so the card's own markup is unchanged, and its
  summary reserves the button's width), so a folded card shows no
  trigger. Its `aria-label` names the card's own kind ("Swap Code Review for
  another kind"), and `aria-haspopup="dialog"` says it opens one; it has no
  `aria-expanded`, because a modal hides the page that would report it.
- The sheet is a native `<dialog>` opened with `showModal()`. That puts it in
  the top layer, out of reach of the transform pull-to-refresh puts on the
  page content and above the tab bar and save-status banner, and makes the
  rest of the page inert, so focus stays in the sheet. It has a header with
  the title and a Close button, the next-set line, the scrolling list, and a
  footer with the chosen kind's consequence block, an error line and the
  buttons. The page behind doesn't scroll (`html:has(...)` sets
  `overflow: hidden`), and pull-to-refresh ignores a touch while a modal
  dialog is open.
- Close, Cancel, Escape (the dialog's `cancel` event) and a click on the
  backdrop each dismiss the sheet, reset the choice to the current kind and
  return focus to the trigger. A click counts as a backdrop click only when
  both its `pointerdown` and its `click` landed on the dialog element itself,
  since a drag from inside the sheet out onto the backdrop also ends with a
  click on the dialog. There is no drag handle or swipe: a handle that
  doesn't drag would be a false affordance, and a gesture would be more touch
  code beside pull-to-refresh. `closedby="any"` would handle the backdrop
  natively, but Safari doesn't support it yet.
- After a swap the card still shows today's kind, so a line under the title
  row says what the next set uses there, and the rows badge that kind "In
  your next set" and the card's kind "In today's set". A row can carry two
  badges: when the card's own kind is now the other place's stored kind, it
  is both "In today's set" and "Already daily", and both show.
- Each kind is one row: a `<label>` around its radio, with the name and its
  state badges on the first line and the kind's `SectionKindGuide` `short`
  line under it. The checked row also shows the kind's example; the others
  render it `hidden`. Each radio is named by `aria-labelledby` (its name and
  badges only), and its `aria-describedby` names its line, its example and,
  for an available kind, its consequence block in the footer. A disabled
  row dims only its radio and name, so the reason and badge keep their
  contrast.
- An option's state is `DailyKindSwap.refusal` for that kind: `unchanged` is
  "Now", the other daily kind is disabled under an "Already daily" badge, any
  other reason disables it with that reason's sentence in place of its
  `short` line, and no reason makes it available. Disabled radios use
  `disabled`, so the arrow keys skip them. A refusal of the place's own kind
  (an ended trial) closes the picker: the reason replaces the next-set line,
  no list follows, and opening the sheet focuses Close.
- The next-set line says the current set keeps its sections and the swap
  starts with the next set, with the paused wording while generation is
  paused.
- The primary button reads "Swap" until a different, available kind is
  checked, then "Swap to Architecture Decision". The server renders each
  kind's label onto its radio (`data-confirm-label`), and the controller
  copies the checked one across.
- Sentences on the incoming kind: a fourth's siblings stop appearing; the
  daily sections can no longer share a concept (shown when the current pair
  can share one through `DayHosts` and the new pair can't); a stored weight
  or exclusion does nothing while the kind is daily.
- The warning on the outgoing kind opens the chosen kind's consequence
  block, directly above the buttons, and the primary button points at the
  block. Suppression comes first, at any size: a fourth swapped for a fourth
  won't appear at all, and neither will an excluded kind whose group still
  has a kind turned on. Then, only on a two-section day: a fixed setting of 2
  means the kind won't appear at all; on Automatic, an excluded kind won't
  appear at all, a braked day (the row's `plan_notes["brake"]`) gets "will
  rarely appear until your sets grow" with no figure, since the brake blocks
  coverage, and any other kind appears about once every N weeks as a
  coverage addition, followed by the line that the pair also decides when
  sets grow. N counts the new pair's optional kinds the user hasn't
  excluded; `docs/code-notes/app/models/daily_kind_swap/consequences.md` has
  the formula.
- Swaps go one at a time through one `CodeGymSaveStatus.queue` line, each
  reading its version when it is sent, and name the exercise and generation
  (`draft_scope`) the page shows, so the reply's panels are for that set
  even past midnight. When another tab has regenerated it, the reply sends
  no panels, the cards stay as they are, and the card says to reload.
- While a swap saves, the buttons and Close are disabled, the list is
  `inert`, the footer says "Saving…", and Escape and backdrop clicks are
  ignored. Chrome still closes a sheet on a second Escape after refusing the
  first, so a swap can be left saving while another card's sheet is used;
  that is why the one-at-a-time queue still matters.
- A save replaces every card's panel from the reply (`panels`), so both
  sheets carry the new version and the new pair's disabled options, and a
  second swap works without a reload. When the reply carries `want_it_today`,
  the sheet stays open in a saved state: the reply's sentence, the "Want it
  in today's set?" line with its cost and a link to the existing "Generate
  new set" button, and one "Done" button. The saved state survives another
  card's reply replacing the panel. Otherwise the sheet closes, the
  sentence is announced in the card's polite live region, focus returns to
  the trigger, and the stored-kind line under the title row shows the
  change. The offer comes only after a save, so regeneration never sits
  next to the swap's own button as a second choice.
- A reply shows in the sheet only while the sheet is still wanted, focus is
  the card's, and no ancestor is inert. Otherwise the sheet stays closed: it
  never comes back after the reader left it during the save, and a submit
  that holds the form inert never gets a modal over it. In that case the
  sentence and the want-it-today offer, with its link, show visibly on the
  card instead.
- A failure shows in a line in the sheet's footer and in the save-status
  banner, which the leave gate reads but which sits behind the scrim. Under
  the rule above, the sheet stays open, keeps the submitted kind when it is
  still offered, and focuses an enabled control; a 409 also carries fresh
  panels, and the sheet stays open on the stored pair and version, so the
  next try saves. When focus has moved elsewhere, or the reader left the
  sheet during the save, the sheet stays closed, and opening it by hand
  shows the kept choice (or the stored pair, after a 409) and the error.
- When the answer form's leave gate locks the form (`relockAndLeave`), any
  open sheet closes first, since a modal dialog inside a subtree that turns
  inert would stay on screen with nothing reachable.
- Discoverability: the welcome page names the default pair and says either
  can be swapped from its card. The first delivered daily card of an
  unsubmitted set carries "New: the button at the top of this card swaps
  this daily section for another kind." under its title row while the
  account has no swap events and fewer than
  `Picker::HINT_UNTIL_SUBMITTED_DAYS` submitted days. It names no glyph,
  since an arrow character renders differently across fonts and reads badly
  in VoiceOver.

## The competency gate

`CompetencyGate` reads each day's own pair: a `Day` carries
`DailyExercise#daily_kinds`, growth counts a result only when its kind was
daily that day, and `Evidence#optional_state` uses the row's pair. A change
of pair neither reclassifies earlier days nor resets an earned size. See
`docs/decisions/competency-gate.md`.

## Prompt wording that still assumes the default order

The generation prompt names sections by position in places, which is right
only for the default pair's order:

- Seven kinds' own guidance opens with a fixed ordinal: design comparison
  ("The second section is…"), architecture, security review and Parsons
  ("The third section is…"), and plan review, ambiguity hunt and pseudocode
  to code ("The fourth section is…").
- `GenerationPrompt`'s retention and established blocks speak of "the fourth
  section".

The layout puts a pair's kinds first in stored order, so for a pair such as
architecture and code review, architecture comes first while its guidance
still calls it the third section. A default account is unaffected, which is
why this PR leaves the wording alone: changing it rewrites all 263
prompt snapshots. Naming each section by its kind instead ("the architecture
section") is a precondition for PR 2, the first change that can write a
non-default pair, and lands before it or with it as its own snapshot update.
That change is #415.

The lines that compared a section with `code_review` or `pattern` now
render only beside them (`alongside:`, recorded in
`kind-named-prompt-sections.md`), and `generation_prompt_pair_coverage_spec`
renders every reachable pair to hold it.

## Other PR 2 preconditions

- Deploy order: the worker must run this PR's code before any pair other
  than the default can be stored. A worker still on older code writes rows
  without `daily_kinds`, and those rows read as the default pair. Satisfied:
  #408 is already on `main`, a release ahead of the swap endpoint, so even a
  worker one release behind the web service writes the key.
- Pair-dependent view logic: `api_keys/edit.html.erb` reads
  `DailyKinds.for` four times per render, and
  `dashboard/_level_suggestion.html.erb` decides `in_place` from
  `KindPreferences#offered` inline. Before PR 2 adds more branches on the
  pair, resolve the pair once in the controller and have the server state
  the answer, as the "server decides" pattern asks.
