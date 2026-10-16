# app/services/daily_plan.rb

## `FOURTH_BUCKETS`

No `code_review`, pattern or third section can host a fourth bucket's concepts, so those buckets never enter the non-fourth reinforcement pool.

## `.for`

The plan chooses the day's concepts so the caller can compare what was offered with what the provider used (`AiService#log_retention`).

## `.main_track`

Reinforcement is truncated to today's hosts because the prompt demands every concept it lists.

Every reinforcement entry, drilled or from recent history, must pass the same `.host_test`: some non-fourth kind planned today can tag it through `DayHosts`. `User#concepts_needing_reinforcement` applies it to both through its `hostable:` argument. A bucket check alone let through a concept no section could tag, such as a meta-skill concept on a two-section `schema_review` day, where code review takes only data-modeling concepts and design comparison never takes meta-skill ones. A history entry left out is offered again on a later day that can host it, while it is still in recent history.

The capacity count (every non-fourth kind) is deliberately approximate: on some days the fixed kinds host fewer concepts than that, and placement is advisory anyway.

## `.code_review_source_for`

The real-source choice is a second roll inside the mode, so `CODE_REVIEW_MODE_WEIGHTS`' three-way split stays exact.

## `.hostable_buckets`

Only `.established_concepts_for` reads this bucket list. Established concepts are optional prompt annotations, not concepts the prompt demands, so the looser bucket rule is enough there; reinforcement and retention checks use `DayHosts` instead.

## `.retention_checks_for`

Checks are ranked by overdue ratio rather than raw due date, and truncated only after ranking, to match the reservation test in `.overdue_retention_check_pending?`.

## `.established_concepts_for`

Reinforcement and due checks carry stronger prompt annotations, so any concept they claim is left out of the established list.

## `.established_in_buckets`

The query builds one condition per bucket and ORs them, so a language concept cannot qualify by matching the architecture list.
