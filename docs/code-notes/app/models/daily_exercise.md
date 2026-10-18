# app/models/daily_exercise.rb

## `#with_response_locked`

Every writer that touches both rows takes the exercise first, then the
response: `RegenerateExerciseJob`, `User#carry_forward` and
`ResponsesController#save_answers_under_lock`. One order means two of them
wait for each other instead of deadlocking.

The response is read with `DailyResponse.lock.find_by`, not `#lock!` on a
loaded association, so a response deleted by `#start_over` after the
exercise was loaded comes back as nil rather than raising, and one submitted
in the meantime comes back as committed.

It finds the response by exercise alone. A unique index on
`daily_responses.daily_exercise_id` means an exercise has at most one
response, so the plain `has_one :daily_response` reads the same row. Before
that index nothing stopped a second row on the same exercise, and locking the
wrong one could let `RegenerateExerciseJob` miss a reviewed response and
replace the set under it.

## `REGENERATION_STALE_AFTER`

The regeneration claim has to outlast the longest a healthy
`RegenerateExerciseJob` can run. Otherwise the dashboard stops reporting
"pending" while the job is still working. A second `/regenerate` could then
take the stale claim, and the first job would throw away its paid result when
it found a different token under the lock.

The window equals `REGENERATION_DEADLINE`, the deadline the job runs under
(`GenerationDeadline`, measured from the claim). That deadline is one
worst-case judged pass plus `JOB_PICKUP_MARGIN`: the draft call, which retries
a 429 or 5xx after a full 300 s read (946 s), then one judge call (181 s), plus
the 60 s the old six-minute value allowed for a worker to pick the job up. It
comes to 1,187 s, about 20 minutes. The deadline refuses any call whose worst
case would end after it, so no healthy job outlives the claim, and a judged
day's full budget (2,302 s) never has to fit in the window. The cost is that a
worker which dies mid-call keeps `/regenerate` refused, and the page on its
generating state, for that long.

The generating poller sizes its attempts from the larger of this window and
`AiService::JUDGED_GENERATION_BUDGET`, so it keeps polling for the whole
window.
