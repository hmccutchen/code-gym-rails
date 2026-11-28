# app/services/practice_generation.rb

## Capture and commit

`.capture` freezes the owner's settings, date, and schedule context under
the user lock. Active capture reads practice evidence for all offered kinds
through `KindPreferences.offered_to`, so eligible optional kinds can carry
their own requests and struggle evidence. Initial commit checks the captured
predecessor again. An existing set for the date wins a duplicate attempt.

Commit writes `section_order` with the content. For formats 2 and 3, the generated
keys must match the single selected key. Historical-format and inactive
results derive the manifest through the recorded layout. Replacement checks
the exercise claim and absence of an active addition under lock, then writes
content and manifest together. For a row with a schedule, the replacement's single-slot plan already carries the
original turn and service continuation. Replacement of a row without a
schedule leaves the schedule absent.

## `#record_judge_solves`

New, replacement and append commits call it inside the transaction that
writes the set, after the row is written, so the records and the set land
together. A replacement calls it under `with_response_locked` after
`update!`, so a superseded or blocked run writes nothing, and the new records
carry the new `generated_at` as their `set_generated_at`, next to the
replaced set's.

A bookkeeping failure must never cost the engineer their set. The records go
in a savepoint (`requires_new: true`), so a `JudgeSolve::RecordError` rolls
back only the records. The warning names the user, the exercise and the
error's message, which `JudgeSolve.record!` limits to constraint and
attribute names, never row values.

`draft_model` is read only when there is something to record, from the
service that drafted the set (`AiService#model_for("generate_exercise")`).
A set with no solves records nothing.

This method lived in `RecordsJudgeSolves`, a concern under
`app/jobs/concerns`, while both generation jobs called it. Once
`PracticeGeneration` became its only caller, a service including a job
concern made jobs and services depend on each other, which archspec's
`no_cycles` check refuses, so the method moved here (#751).

## Appending one requested section

`.capture_addition` and `.commit_append` delegate to `PracticeGeneration::Addition`.
Append reuses captured settings, predecessor validation and judge-solve
recording, while preserving earlier content, `generated_at` and draft scope.
Its claim, manifest, requested kind and provider-key identity are rechecked
before the write. The existing scheduling predecessor is read for planning
and freshness; append never rewrites a different predecessor row. The target's
schedule-note behavior is documented in
`docs/code-notes/app/services/practice_generation/addition.md`.
