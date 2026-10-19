# app/models/daily_kind_swap/consequences.rb

The sentences the card's picker shows for one available option, before
Confirm. The wording and the cases are in
`docs/decisions/daily-kinds.md` ("The card's control"); this note covers why
the code is shaped the way it is.

## Pure, with every input passed in

It takes the pair, the place, the incoming kind, a `KindPreferences`, a `Day`
(the size setting, today's planned size and whether the gate's brake held,
from the row's `plan_notes["brake"]`), the user's language buckets, and
whether the stored pair can share a concept. It reads no record.
`DailyKindSwap::Picker` gathers those once per card, including the stored
pair's sharing answer, which is the same for every option; only the proposed
pair's answer is computed per option. The spec drives every case without a
database.

## Sentences and the warning are separate

`sentences` describe the incoming kind and go in the option's
`aria-describedby`. `warning` describes the outgoing kind, which is the
strongest consequence, so it renders as its own paragraph above Confirm and
Confirm points at it. Keeping them apart in the `Result` lets the view place
each without the browser deciding which is which.

## The order of the warning

Suppression comes first. A daily fourth hides its siblings at every size, and
an outgoing kind rotation would skip never comes back either. "Would skip" is
`!KindPreferences#eligible(group).include?(outgoing)`, the same call rotation
makes, so its fallback (a wholly excluded group rotates anyway) is not
restated. Neither depends on how many sections the day has, so both are
checked before any size rule.

A fixed setting of 2 is exact (coverage never runs on a fixed setting). Every
other size question goes to `CoverageException.applies_to_day?`: asked
without the brake it says whether the day is a two-section Automatic day;
asked with the row's brake it says whether coverage can add a section at
all. An excluded outgoing kind is never added by coverage. While the brake
holds, the copy says the kind will rarely appear until sets grow and gives
no figure. Otherwise the weeks figure applies.

## The weeks figure

`CoverageException.expected_gap_weekdays(candidates:)` owns the cadence: the
larger of `GAP_WEEKDAYS + 1` and `(CAP_WEEKDAYS + 1) × candidates`, and the
candidates are `CoverageException.candidate_kinds`, the same list `.for`
picks from. The picker only rounds it to weeks of five weekdays.
`spec/services/coverage_exception_cadence_spec.rb` runs the real `.for` over
400 synthetic weekdays and checks the steady recurrence equals that figure
for several candidate counts.

## Sharing comes from `DayHosts`

The shared-concept sentence shows when the current pair could share a concept
and the proposed pair could not. "Could share" is the same test
`SharedConcept` relies on: some concept the first daily kind may be asked for,
in one of the user's languages and one of the code-review modes, that
`DayHosts` says every kind in the pair can tag. Restating "pairs with a fourth
never share" here would be a second copy of a rule `DayHosts` owns.
