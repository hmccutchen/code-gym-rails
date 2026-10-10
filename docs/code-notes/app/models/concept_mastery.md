# app/models/concept_mastery.rb

## `RETENTION_OVERDUE_THRESHOLD_MULTIPLIER`

A value of 1 means a check is overdue once it is late by 100% of the concept's own `retention_interval_days`.

## `.evaluate_concept!`

When a concept appears in more than one section, the least favorable section's AI rating represents the day. If any of those sections has no AI rating, the day moves neither mastery nor the streak.

A paused concept returns early. Paused concepts only count down their cooldown, which `.count_down_paused_concepts!` does as the first step of `.record_review!`.

The final `else` branch is the stagnant case: the rating is the same as or worse than the last one.

When the review does not master the concept, the retention schedule is cleared, so a failed retention check sends the concept back into normal reinforcement. `mastered_at` is left alone, because it records the first mastery.

## `.retention_schedule_for`

`mastered_at` is set only on first mastery (`cm.mastered_at || Time.current`). A later retention check must not overwrite it.
