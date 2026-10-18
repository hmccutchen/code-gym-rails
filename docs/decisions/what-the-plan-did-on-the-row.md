# What the plan did, on the row

`daily_exercises.plan_notes` (jsonb,
default `{}`, null false) records `{"size" => count, "size_reason" =>
"setting" | "completion" | "gate" | "brake"}` and `{"daily_kinds" =>
[key, key]}` (the pair the plan used, `docs/decisions/daily-kinds.md`) on
every plan, and
`{"coverage" => kind_key, "coverage_reason" => "gap" | "due_check"}`,
`{"shared_concept" => concept}` and `{"brake" => true}` (the gate's brake
held, so coverage could add nothing; `size_reason` alone can't say so, since
it names completion whenever completion gives the same count), each only when
it applied
(`DailyPlan::Result#notes`). The size is the planned count before any
coverage addition, so a coverage day never reads as a larger planned size;
`DailyExercise#planned_size` reads it and `.planned_size_before(date)` finds
the latest earlier one. It is server-owned and written with the row
from the plan that produced it, never recomputed while rendering: both
generation paths hand it back on `AiService::JudgedSet#plan_notes`
(`#generate_unjudged_exercise` on the single-stage path,
`#generate_judged_exercise` on the judged one; `#generate_exercise` still
returns only the set).
`RegenerateExerciseJob` rewrites it from the new plan, clearing it when the
new plan recorded nothing, and carry-forward moves it with the row because
it is on the row. No backfill: no earlier plan added a section or shared a
concept, and a row from before sizes were recorded has no `size`, which
the transition log and the dashboard's size lines read as nothing to
compare against.
