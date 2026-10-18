# app/models/daily_kind_swap/consequences.rb

The sentences the card's picker shows for one available option, before
Confirm. The wording and the cases are in
`docs/decisions/daily-kinds.md` ("The card's control"); this note covers why
the code is shaped the way it is.

## Pure, with every input passed in

It takes the pair, the place, the incoming kind, a `KindPreferences`, the size
setting, today's planned size and the user's language buckets, and reads no
record. `DailyKindSwap::Picker` gathers those once per card, so one page
render builds each preferences object once, and the spec drives every case
without a database.

## Sentences and the warning are separate

`sentences` describe the incoming kind and go in the option's
`aria-describedby`. `warning` describes the outgoing kind, which is the
strongest consequence, so it renders as its own paragraph above Confirm and
Confirm points at it. Keeping them apart in the `Result` lets the view place
each without the browser deciding which is which.

## The order of the warning

Suppression comes first. A daily fourth hides its siblings at every size, and
an excluded outgoing kind that rotation would skip (its group still has a kind
left on) never comes back either. Neither depends on how many sections the
day has, so both are checked before the two-section test, and a larger day
or a coverage addition never contradicts them. When the outgoing kind's
whole group is excluded, rotation falls back to the group
(`KindPreferences#eligible`), so it still rotates at three or more sections;
that case reaches the size checks like any other kind.

At two sections a fixed setting of 2 is exact (coverage never runs on a fixed
setting). On Automatic, an excluded outgoing kind is never added by coverage,
and otherwise the weeks figure applies.

## The weeks figure

Coverage adds at most one section per `CAP_WEEKDAYS + 1` weekdays and only
for a kind unseen past `GAP_WEEKDAYS`, so the candidate kinds take turns. The
wait for one kind is the larger of `GAP_WEEKDAYS + 1` and
`(CAP_WEEKDAYS + 1) × candidates`, rounded to weeks of five weekdays. The
candidates are the new pair's optional kinds the user has not excluded,
because coverage never adds an excluded kind. Both constants are read from
`CoverageException`, so the figure follows a change there.

## Sharing comes from `DayHosts`

The shared-concept sentence shows when the current pair could share a concept
and the proposed pair could not. "Could share" is the same test
`SharedConcept` relies on: some concept the first daily kind may be asked for,
in one of the user's languages and one of the code-review modes, that
`DayHosts` says every kind in the pair can tag. Restating "pairs with a fourth
never share" here would be a second copy of a rule `DayHosts` owns.
