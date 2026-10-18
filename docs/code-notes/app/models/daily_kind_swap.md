# app/models/daily_kind_swap.rb

One swap of one daily place, from the card's picker. The full rules are in
`docs/decisions/daily-kinds.md` ("The swap"); this note covers why the code
is shaped the way it is.

## Why it lives in `app/models`

It reads `DailyExercise#regeneration_offered?`, which reads trial state, and
CLAUDE.md keeps trial state out of everything under `app/services`. It sits
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
left open across midnight therefore records `no_set` and offers no
regeneration, which is right: that set is no longer today's.

## Storing the default as an empty list

Swapping back to `DailyKinds::DEFAULT` stores `[]`. Storage is sparse, like
the kind preferences, so an account that swapped and swapped back reads the
same as one that never did.
