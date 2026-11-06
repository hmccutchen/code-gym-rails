# app/models/concept_mastery.rb

## `RETENTION_OVERDUE_THRESHOLD_MULTIPLIER`

A value of 1 means a check is overdue once it is late by 100% of the concept's own `retention_interval_days`.

## `.record_review!`

The caller holds user then response locks, supplies actual pre-merge review
keys, and saves the response in the same transaction. The default-off
compatibility writer selects reconciliation for an enrolled user through
fresh uncached receipt/suffix queries under the user lock. Untouched users
retain legacy batch application without new state.

`DailyEvidence` projects one contribution per response/concept/bucket.
`Reconciliation` replaces it at its original position, preserves clocks and
later operations, and compacts only irrevocable prefixes. It assigns new
JSON hashes rather than relying on in-place dirty tracking.
`Transition` owns all policy formulas, shared by both modes.
See `docs/decisions/daily-mastery-reconciliation.md` for formats, reservations,
legacy limits and the S/C/A deployment contract.

A paused concept returns early. Cooldown advances only on a response's
first assessed-core-answer transition, checked under the response lock by
`ResponseReview`. The model additionally requires submission and an assessed
successful core section. Supplementary bug hunts, invalid grades and walkthrough-only successes cannot
count a session or change mastery. Successful skipped retention deferral
remains separate and still excludes a concept answered anywhere on the day.

## `Transition#struggle`

The streak resets when the rating improved or there was no earlier rating. Otherwise it is the stagnant case: the rating is the same as or worse than the last one, so the streak grows and can step the tier down.

The retention schedule is cleared, so a failed retention check sends the concept back into normal reinforcement. `mastered_at` is left alone, because it records the first mastery.

## `Transition#master`

`mastered_at` is set only on first mastery from the operation's captured
timestamp. Later retention checks never overwrite it. Replacing a
provisional first success can remove it; a subsequent genuine success then
keeps that later operation's timestamp.
