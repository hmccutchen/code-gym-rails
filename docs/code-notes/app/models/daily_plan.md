# app/models/daily_plan.rb

## `FOURTH_BUCKETS`

No `code_review`, pattern or third section can host a fourth bucket's concepts, so those buckets never enter the non-fourth reinforcement pool.

## `.for`

The plan chooses the day's concepts so the caller can compare what was offered with what the provider used (`GenerationDiagnostics`' retention log).

## `.concept_tracks`

The fourth track takes the day's fourth kind from the planned kinds, so a daily fourth and a rotated fourth are planned the same way. Under the pair's layout a day never holds two. `Result#fourth` is derived from `#kinds` the same way rather than stored beside the rotation, so a hand-built plan cannot name one fourth kind in its rotation and another in its prompt lines.

The fourth track also asks `DayHosts` which concepts that kind can tag, through `fourth_track(..., hosts:)`, for its reinforcement, its overdue check, its due checks and its established concepts. It used to take every concept in the bucket, because the fourth kind alone tags that bucket. It matters when the week's featured concept (`Result#featured_concept`) is one the fourth kind hides from itself: that concept is no longer planned onto the section, and a due check on it lands in `waiting_checks` as `no_host` until the week turns over (`docs/decisions/the-weekly-featured-concept.md`). On a day with a featured concept, `.for` also builds a `DayHosts` without it, and `waiting_checks` marks a `no_host` check `held_by_featured: true` when that one would host it; a day without a featured concept builds no second `DayHosts` and marks nothing. For any other day the answer is the kind's whole vocabulary, so nothing changes.

## `.main_track`

Reinforcement is truncated to today's hosts because the prompt demands every concept it lists.

Every reinforcement entry, drilled or from recent history, must pass the same `.host_test`: some non-fourth kind planned today can tag it through `DayHosts`. `User#concepts_needing_reinforcement` applies it to both through its `hostable:` argument. A bucket check alone let through a concept no section could tag, such as a meta-skill concept on a two-section `schema_review` day, where code review takes only data-modeling concepts and design comparison never takes meta-skill ones. A history entry left out is offered again on a later day that can host it, while it is still in recent history.

The capacity count (every non-fourth kind that `DayHosts#planning_host?` accepts, so a `bug_hunt` day's `code_review` doesn't count) is deliberately approximate: on some days the daily kinds host fewer concepts than that, and placement is advisory anyway.

## `.code_review_source_for`

The real-source choice is a second roll inside the mode, so `CODE_REVIEW_MODE_WEIGHTS`' split stays exact. `RealSource.pool(:bug_hunt)` is empty, so a `bug_hunt` day is never grounded.

## `CODE_REVIEW_FILE_WEIGHTS`

The files roll says only whether today's `code_review` may show several files; it gives no count. The count depends on the rung `code_review` is pitched at, which `DailyPlan` never reads (it reads no `KindDifficulty`), so `ExerciseSection::CodeReview.file_range` turns the roll and the rung into a range later, in `GenerationPrompt` and `ExerciseDraft`. A day grounded in a `RealSource` excerpt is always `:single` and skips the roll, so an excerpt is never split into files. The weight is `multi: 0.25` since the launch with guards (`docs/decisions/multi-file-code-review.md`); setting it back to `0.0` turns the shape off for new days. `spec/support/roll_defaults.rb` pins the roll to `:single` for every example, so specs stay deterministic.

## `.hostable_buckets`

Only `.established_concepts_for` reads this bucket list. Established concepts are optional prompt annotations, not concepts the prompt demands, so the looser bucket rule is enough there; reinforcement and retention checks use `DayHosts` instead. The buckets come from the day's non-fourth kinds, through `ConceptBucket.for`, rather than always including the language, so a pair whose only regular section is architecture never lists a language concept. For the default pair the list is unchanged: the language first, then `architecture` when that kind is planned.

## `.retention_checks_for`

Checks are ranked by overdue ratio rather than raw due date, and truncated only after ranking, to match the reservation test in `.overdue_retention_check_pending?`.

## `.established_concepts_for`

Reinforcement and due checks carry stronger prompt annotations, so any concept they claim is left out of the established list.

## `.established_in_buckets`

The query builds one condition per bucket and ORs them, so a language concept cannot qualify by matching the architecture list.

## `CODE_REVIEW_MODE_WEIGHTS` and `UNJUDGED_CODE_REVIEW_MODE_WEIGHTS`

`bug_hunt` is rolled only on a judged day. `.for` takes `judged:` from the path that called it (`AiService#generate_judged_exercise` passes true, `#generate_unjudged_exercise` false), because a model may not name `AiService` to ask `.judged_on?` itself. An unjudged day rolls `UNJUDGED_CODE_REVIEW_MODE_WEIGHTS`, the same weights without `bug_hunt`: a weekend `bug_hunt` would ship with no judge to reject a snippet that is correct as written, holds a second trap, or uses code outside the core language. `WeightedRoll` divides by the remaining total. It is its own constant so a spec can pin the roll on either path (`pin_code_review_mode` stubs both).

## `.code_review_gotcha_for`

A `bug_hunt` day picks its trap from `BugHuntGotchas` here, never-seen-first from `plan_notes["bug_hunt"]`, and `Result#notes` writes the id back there. The trap is picked once, on every `bug_hunt` roll, and `.day_gotcha` attaches it only to a version of the day whose plan includes a `code_review` section; a plan without one records none. A planned section the judge or ingest drops still records the trap, and `BugHuntGotchas.last_seen_for` is what requires delivery before the trap counts as seen. `.for` builds `DayHosts` through `hosts_for`, so when coverage adds `code_review`, the tracks are replanned with hosts that withhold the trap's concept from the other sections. The planner and the prompt therefore always see the same trap (#656). `BugHuntGotchas.last_seen_for` counts a day only when its stored `code_review` section has a `purpose`, so a section the judge or ingest dropped never counts as seen. It doesn't depend on the concept tracks, since a `bug_hunt` section serves no reinforcement entry or retention check. A `bug_hunt` day is also single-file without rolling: `ExerciseSection::CodeReview.multi_file_mode?` says so.
