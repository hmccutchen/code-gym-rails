# app/jobs/concerns/records_judge_solves.rb

`GenerateDailyExercisesJob#write_set` and `RegenerateExerciseJob#regenerate`
call `#record_judge_solves` inside the transaction that writes the row, after
the row is written, so the records and the set land together. A regeneration
calls it under `with_response_locked` after `update!`, so a superseded or
blocked run writes nothing, and the new records carry the new `generated_at`
as their `set_generated_at`, next to the replaced set's.

A bookkeeping failure must never cost the engineer their set. The records go
in a savepoint (`requires_new: true`), so a `JudgeSolve::RecordError` rolls
back only the records. The warning names the user, the exercise and the
error's message, which `JudgeSolve.record!` limits to constraint and
attribute names, never row values.

`draft_model` is read only when there is something to record, from the
service that drafted the set (`AiService#model_for("generate_exercise")`).
An unjudged weekend set has no solves and records nothing.
