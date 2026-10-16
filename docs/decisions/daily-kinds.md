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
only one, so `recorded` falls back to `DEFAULT`.

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

Keeping that entry across a swap is not built yet. PR 2 or PR 3 has to add
two things:

- The Exercise mix form posts only the rows on screen, and a daily kind has no
  row there, so the next save overwrites the stored weights and exclusions
  without the daily kind's entry. The save has to merge stored entries for
  daily kinds back in.
- `section_kind_weights_name_rotatable_kinds` and
  `excluded_section_kinds_name_rotatable_kinds` check every stored entry
  against the current layout. They have to check only the entries a save adds
  or changes, or a kept entry for a daily kind refuses the save.

`User#every_slot_keeps_a_kind` runs only when the exclusions change. A new
pair can therefore leave its old slot with every kind excluded, and the save
still goes through, because `SectionRotation.eligible` falls back to the whole
slot in that case.

## What still reads the default pair

`CompetencyGate.for` and `CompetencyGate::Evidence` read
`DailyKinds::DEFAULT`, not each day's pair. Every stored day holds the
default pair until swapping ships, so this matches the stored history.
Tagging each day with its own pair is the next PR (1b).
