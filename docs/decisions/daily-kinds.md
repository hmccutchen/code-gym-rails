# Daily kinds

`DailyKinds` (`app/models/daily_kinds.rb`) decides which section kinds a
user gets in every set. Before it, "every day holds code review and design
comparison" was a facet on two kinds (`fixed?`) that a dozen readers asked
the registry about. Now the pair is a per-user value, and every reader that
needs it takes it as an argument. Nothing can change a user's pair yet: the
swap itself is a later PR (see
`docs/superpowers/specs/2026-10-16-daily-kind-swap-design.md`). Until then
every account plans, prompts and renders exactly as before.

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
  `AiService#draft_exercise` and `script/forced_concept_drafts.rb` read.
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
sections. `AiService::JUDGED_GENERATION_BUDGET` reads the larger of the two.

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

`User#rotatable_keys` reads the user's layout, so a weight or exclusion can't
be added for a daily kind. Rotation and coverage read only optional slots, so
a weight or exclusion stored on a kind before it became daily is ignored while
it is daily.

The entry is kept across a swap, so swapping a kind back restores its
setting:

- The Exercise mix form posts only the controls on screen. A daily kind has
  no weight row there, and while a fourth kind is daily its two siblings have
  no row at all, so neither their weights and exclusions nor their difficulty
  targets and locks are posted. `ProfileController` passes every save through
  `User#keep_unrendered_preferences`, which merges back the stored weights and
  exclusions for kinds outside `ExerciseSection.rotatable` and the stored
  targets and locks for kinds outside `ExerciseSection.pickable`, the two sets
  Setup renders controls for.
- A Setup page left open while another tab swaps a kind was rendered for the
  old pair. Its next save gets the usual 409, and the reply's
  `layout_changed`, decided by the server from the `layout` the page posts,
  makes the page reload instead of saving with controls missing.
- `section_kind_weights_name_rotatable_kinds` and
  `excluded_section_kinds_name_rotatable_kinds` check only the entries a save
  adds or changes, so a kept entry for a daily kind never refuses a save, and
  a new entry for one still is.

`User#every_slot_keeps_a_kind` runs when the exclusions or the pair change. A
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
today), `not_in_set` (today's set does not hold the outgoing kind, as after
an earlier swap or a judge drop), `submitted`, then `answered` or
`unanswered` through `DailyResponse#answered?`. `planned_size` copies today's
`plan_notes["size"]` and stays null for `no_set`, and also for a held set
planned before `plan_notes` recorded a size. The model is
`DailyKindSwapEvent` on the `daily_kind_swaps` table, since `DailyKindSwap`
is the swap itself.

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

Two lines assume `code_review` is in the day without naming a position:
`DesignComparison`'s "the same as the code review's" and `SecurityReview`'s
"the same bar as code_review's snippet". A pair without `code_review` makes
them point at a section that is not there. PR 2 either gates them on
`code_review` being planned or rewords them to stand alone.

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
