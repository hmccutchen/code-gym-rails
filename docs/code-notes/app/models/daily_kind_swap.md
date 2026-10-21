# app/models/daily_kind_swap.rb

One swap of one daily place, from the card's picker. The full rules are in
`docs/decisions/daily-kinds.md` ("The swap"); this note covers why the code
is shaped the way it is.

## Why it lives in `app/models`

It reads `DailyExercise#regeneration_offered?`, which reads trial state, and
CLAUDE.md keeps trial state out of everything in `IsolationScope`, which
includes `app/services`. It sits
beside `ConceptDrills`, the other user-locked write that is not a record.

## The order of the checks

Shape first (a place and a kind that exist), then the version, then the
pair rules. A stale page is refused before the pair rules, because the rules
read the stored pair, which is exactly what the page no longer shows; telling
a stale page "already a daily section" would describe a pair it never saw.

## Why the version is required

A swap bumps `section_kind_preferences_version`, so a second swap from the
same page, or a swap from a page loaded before an Exercise mix edit, would
otherwise apply to a pair the person isn't looking at. A missing version is
refused as stale, the same as an old one.

## The reply reads today's set after the save

`want_it_today` and `today_section` read the set for today in the user's
zone when the request is handled, never the set the page was showing. A page
left open across midnight therefore offers no regeneration, which is right:
that set is no longer today's.

`today_section` and `planned_size` have one exception. When today has no
set and the user is paused, they read the held set (`User#held_exercise`).
A held set moves to today only when a dashboard loads
(`carry_held_set_forward!`), so a swap from a page left open past midnight
would otherwise record `no_set` while a set is held. That would under-count
the swaps that column exists to find: people who wanted the set they were
on changed. `want_it_today` still reads today's row only, since regeneration
acts on today's set.

## `.refusal` is for the picker

PR 3's picker renders one option per kind and marks the ones it can't
offer. It asks `DailyKindSwap.refusal(user, place:, kind:)` for each, which
runs the same shape and pair checks as a save without a version, so the
disabled options and a refused post can never disagree.

## The pair rules are not restated here

Whether a kind repeats one already daily, or is a second fourth, is
`DailyKinds.conflict`, which `DailyKinds.normalize` also places kinds with;
the swap only maps its answer to a reason. Whether a slot would be left with
every kind excluded is `SectionKindSettings#emptied_slots`, built on
`KindPreferences#all_excluded?`, the same test rotation's fallback reads.

## Storing the default as an empty list

Swapping back to `DailyKinds::DEFAULT` stores `[]`. Storage is sparse, like
the kind preferences, so an account that swapped and swapped back reads the
same as one that never did.
