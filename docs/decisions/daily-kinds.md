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
- `DailyKinds.problems_with(keys)` is the write-time check `User` runs.

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
only one, so `recorded` falls back to `DEFAULT`.

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

## Weights and exclusions on a daily kind

`User#rotatable_keys` and `User#every_slot_keeps_a_kind` read the user's
layout, so a daily kind can't be weighted or excluded. A weight or
exclusion already stored on a kind that becomes daily stays stored and is
ignored while the kind is daily, because rotation and coverage only read
optional slots. It applies again when the kind goes back to the pool. That
keeps storage sparse and makes a swap reversible.

## What still reads the default pair

`CompetencyGate.for` and `CompetencyGate::Evidence` read
`DailyKinds::DEFAULT`, not each day's pair. Every stored day holds the
default pair until swapping ships, so this matches the stored history.
Tagging each day with its own pair is the next PR (1b).
