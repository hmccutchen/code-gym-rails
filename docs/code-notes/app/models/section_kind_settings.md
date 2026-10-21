# app/models/section_kind_settings.rb

## Why a value object

`User` used to hold seven validators, the version-bump condition and two
helpers for the section-kind preference columns (#435). They read only those
columns and their stored values, so they now live in this object, built from
plain hashes. `User` keeps one validation, `section_kind_settings_hold`, which
adds `#problems` to its errors, and its `before_save` asks `#changed?`
whether to bump `section_kind_preferences_version`. The specs build the object
from hashes and need no database.

`#problems` returns the same messages, in the same order, as the validators
did, so a person sees the same refusal.

## The rules run only on a changed field

`#problems` checks `section_kind_weights`, `excluded_section_kinds`,
`section_kind_levels`, `locked_section_kinds` and `daily_section_kinds` only
when that column differs from its stored value (`#changed?`). If the rules
ran on every save, a kind retired from the registry would make every user who
names it unsavable, logins included.

## `#locks_without_levels`

This runs as a model validation because a CHECK constraint cannot run
subqueries. A lock that slips past it anyway is inert, because
`KindDifficulty#locked?` ignores a lock on a kind with no target.

## `#emptied_slot_problems` and `#emptied_slots`

`#emptied_slots` reads the slot roster from `ExerciseSection.optional_slots`
for the user's own pair (`#daily`) or the pair a caller passes, so a future
slot that holds several kinds needs no edit here. It tests each slot with
`KindPreferences#all_excluded?`, the predicate rotation's whole-slot fallback
reads, and skips single-kind slots. `#emptied_slot_problems` runs when the
exclusions or the pair change, and `DailyKindSwap` asks `#emptied_slots`
with the proposed pair to name the kinds in its refusal. A pair that leaves
an optional slot holding only excluded kinds is refused, the same as an
exclusion that would: rotation would otherwise fall back to the excluded
kinds (`KindPreferences#eligible`), quietly undoing "never show me this".

## `#keep_unrendered` and the rotatable-kind rules

The Exercise mix form posts only the controls it renders, and which those
are depends on the pair. Setup renders a weight and an exclude box for each
kind in a multi-kind optional slot, which is `ExerciseSection.rotatable`, and
difficulty controls for the daily kinds and every optional slot's kinds, which
is `ExerciseSection.pickable`; `spec/requests/setup_unrendered_preferences_spec.rb`
pins that the page renders exactly those. A daily kind has no weight row, and
while a fourth kind is daily its two siblings have no row at all (D1).
`ProfileUpdate#profile_attributes` passes every save through
`#keep_unrendered`, which merges back the stored weights and
exclusions for kinds outside `rotatable` and the stored difficulty targets and
locks for kinds outside `pickable`. A swap can therefore be undone without
losing any of those settings, and an unrelated save never deletes them.
Only entries for kinds still in `ExerciseSection.keys` are kept, so a retired
kind's stored entries drop out on the next save that posts that field.
`#weight_problems` and `#exclusion_problems` check only the entries a save
adds or changes against the pair's rotatable kinds; a kept entry was valid when it
was stored and must not refuse an unrelated save.
