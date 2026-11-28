# app/models/daily_plan.rb

## `FOURTH_BUCKETS`

No `code_review`, pattern or third section can host a fourth bucket's concepts, so those buckets never enter the non-fourth reinforcement pool.

## `.for`

All plans select one exercise through `PracticeSchedule.single_turn`.
`Result#kinds` uses that explicit selection. The regular pair still supplies
preference and retry-budget inputs and is recorded separately in the notes.

`.single_selection` builds `DayHosts` again for the selected kind before
allocating concepts. For an active schedule, `PracticeSchedule.single_plan`
uses that same turn and rereads eligible reinforcement and drill candidates.
Filtering the original list could miss a concept that the preliminary hosts
excluded before the history query applied its limit. Inactive plans use the
existing concept tracks with the selected host and omit the schedule note.
The final hosts also determine waiting retention reasons.

The captured work date controls weekday mode. Kind selection uses delivered
history and keeps it separate from assessed performance. The history window
covers at least two eligible-kind rotations so overdue planning-host
opportunities survive supplementary Bug Hunt deliveries. `.size_for` returns
`DaySize.initial` for every new plan. The initial count is one, independent of the competency gate and coverage
exception. Historical records retain their stored layout; obsolete planning
algorithm cleanup is tracked in #862.
`Result#notes(kind_rungs:)` records the draft's captured rung map without
querying difficulty. The plan also lets retention diagnostics compare the
concepts offered with those the provider used.

## `.concept_tracks`

The fourth track takes its kind from the explicit selection.
`Result#fourth` also reads `#kinds`, so the plan and prompt use the same
kind.

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

Only `.established_concepts_for` reads this bucket list. Established concepts are optional prompt annotations, not concepts the prompt demands, so the looser bucket rule is enough there; reinforcement and retention checks use `DayHosts` instead. The buckets come from the day's non-fourth kinds, through `ConceptBucket.for`, so an architecture-only plan lists concepts from that bucket.

## `.retention_checks_for`

Checks are ranked by overdue ratio rather than raw due date, and truncated only after ranking, to match the reservation test in `.overdue_retention_check_pending?`.

## `.established_concepts_for`

Reinforcement and due checks carry stronger prompt annotations, so any concept they claim is left out of the established list.

## `.established_in_buckets`

The query builds one condition per bucket and ORs them, so a language concept cannot qualify by matching the architecture list.

## `CODE_REVIEW_MODE_WEIGHTS`, `WEEKEND_CODE_REVIEW_MODE_WEIGHTS` and `CODE_REVIEW_MODES`

A weekday rolls `CODE_REVIEW_MODE_WEIGHTS`, which holds no `bug_hunt`. A weekend day takes `WEEKEND_CODE_REVIEW_MODE_WEIGHTS`, whose one entry is `bug_hunt`, so every weekend `code_review` is a bug hunt (`docs/decisions/bug-hunt.md`). `.for` takes `weekend:`, defaulting to `Date.current.on_weekend?`, so a caller can state the kind of day it plans for: jobs use their captured user-local work date, and measurement scripts without a captured context pass `false` so a weekend run plans a weekday set. Every set is judged, so the plan reads no path flag, and multi-file rolls on any day whose mode allows it. The weekend roll goes through `WeightedRoll` with a one-entry table, rather than naming the mode, so a spec can pin it like any other roll (`pin_code_review_mode` stubs both tables, and `roll_defaults` turns the weekend one into a weekday roll). `CODE_REVIEW_MODES` lists every mode once, for the readers that ask what any day could hold (`ConceptHosts`, `DailyKindSwap::Consequences`).

## `.code_review_gotcha_for`

A `bug_hunt` day picks its trap from `BugHuntGotchas` here, never-seen-first from `plan_notes["bug_hunt"]`, and `Result#notes` writes the id back there. The trap is picked once, on every `bug_hunt` roll, and `.day_gotcha` attaches it only to a version of the day whose plan includes a `code_review` section; a plan without one records none. `.for` uses the same selection to build the final `DayHosts` and attach the trap to the result, which keeps the planner, prompt, and ladders consistent. `BugHuntGotchas.last_seen_for` counts a day only when its stored `code_review` section has a `purpose`, so a section the judge or ingest dropped never counts as seen. It doesn't depend on the concept tracks, since a `bug_hunt` section serves no reinforcement entry or retention check. A `bug_hunt` day is also single-file without rolling: `ExerciseSection::CodeReview.multi_file_mode?` says so.

Kind service and assignment service are scoped to the generated language.
Delivered history is filtered by that language before its count window.
This preserves opportunities when a mixed-language learner alternates languages.

## Requested-kind additions

An addition passes `requested_kind` through the existing single-slot selector.
It uses the current pending, reinforcement, retention and drill priorities
and the ordinary host rules for that kind. It does not advance the automatic
turn. A concept still due after the initial exercise may be assigned again to
another suitable kind: generated or unsubmitted work does not satisfy its
retention obligation, and there is no blanket same-day concept exclusion.
The provider also receives delivered-content history for variety guidance.

Captured Bug Hunt traps remain excluded from other concept hosts. When adding
a new Bug Hunt, `BugHuntGotchas.pick` also excludes concepts already exposed
by the current set, using its existing never-seen-first ordering. These
specific trap rules do not promise general semantic spoiler prevention.
