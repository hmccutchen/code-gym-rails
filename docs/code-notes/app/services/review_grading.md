# app/services/review_grading.rb

Grades a day's sections in parallel and assesses their difficulty beside the
grading. It owns the fan-out and every per-section rule: Parsons' computed
rating, the rubric check, the prose judge's switch and fallback, and where the
essential-gap positions are stored. It reaches the provider only through
`Provider`, a set of callables `AiService#review_grading_provider` builds, so
its specs can drive it with lambdas.

## `Provider`

`providers` returns a fresh `Provider` each time it is called, and each thread
calls it once. A service object is not shared between threads, as before the
move, when each section graded through `AiService#fresh_service`.

## `#call`

Each thread has its own service and holds no database connection during the
HTTP call. A failed section is tagged, not raised. The difficulty assessment
thread starts first so its extra provider call overlaps the grading instead of
adding to the wait.

## `#translate_before_grading`

Runs before the fan-out because the provider's `day_context` reads the stored
translation once for every grading thread.

## `#translatable_length?`

A plan over the limit is skipped rather than truncated: code from a clipped
plan would be captioned as the engineer's plan.

## `#merge_difficulty!`

Merges only onto sections that graded; a section the day never asked about must
not acquire a difficulty note.

## `.grade_section`

Grades one section by the same per-section rules, with no difficulty
assessment and no translation. `script/model_comparison.rb` uses it to compare
graders on stored days without billing those extra calls, and it grades a
pseudocode section as written when no translation was saved.
