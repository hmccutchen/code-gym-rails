# app/models/concept_mastery.rb

## `RETENTION_OVERDUE_THRESHOLD_MULTIPLIER`

A value of 1 means a check is overdue once it is late by 100% of the concept's own `retention_interval_days`.

## `.evaluate_concept!`

The intended rule remains one evaluation per concept/day, represented by
its least favourable valid assessed section. Valid partial evidence acts
immediately; an unreviewed sibling does not block it.

The existing writer groups only the newly successful batch. Consequently,
same-concept partial retries can still produce different final mastery,
drill and retention state depending on review order. Issue #726 tracks this
pre-existing implementation gap separately. Eligibility work must not pass
all accumulated successes into the mutating writer on each retry, which
would add duplicate evaluations. The all-at-once least-favourable assertion
remains intact; batch-dependent mastery is not the intended policy.

A paused concept returns early. Cooldown advances only on a response's
first assessed-answer transition, checked under the response lock by
`ResponseReview`. The model additionally requires submission and an assessed
successful section. Invalid grades and walkthrough-only successes cannot
count a session or change mastery. Successful skipped retention deferral
remains separate and still excludes a concept answered anywhere on the day.

## `.record_unmastered`

The streak resets when the rating improved or there was no earlier rating. Otherwise it is the stagnant case: the rating is the same as or worse than the last one, so the streak grows and can step the tier down.

The retention schedule is cleared, so a failed retention check sends the concept back into normal reinforcement. `mastered_at` is left alone, because it records the first mastery.

## `.retention_schedule_for`

`mastered_at` is set only on first mastery (`cm.mastered_at || Time.current`). A later retention check must not overwrite it.
