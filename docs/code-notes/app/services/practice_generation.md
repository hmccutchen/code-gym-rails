# app/services/practice_generation.rb

## `#record_judge_solves`

`#commit_new` and `#commit_replacement` call it inside the transaction that
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
