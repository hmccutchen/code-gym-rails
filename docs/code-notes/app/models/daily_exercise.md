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

The job makes one single-stage draft call. That call retries a 429 or 5xx
after a full read, so its worst case is
`AiService.worst_case_call_seconds(GENERATION_READ_TIMEOUT)`, 946 s at a 300 s
read timeout. The window is that worst case plus `JOB_PICKUP_MARGIN`, the 60 s
the old six-minute value already allowed for a worker to pick the job up. It
comes to 1,006 s, about 17 minutes. The cost is that a worker which dies
mid-call keeps `/regenerate` refused, and the page on its generating state,
for that long instead of six minutes.

The generating poller sizes its attempts from the larger of this window and
`AiService::JUDGED_GENERATION_BUDGET`, so it keeps polling for the whole
window.

## `#regeneration_offered?`

The regenerate button's three conditions: the response is not reviewed, the
day has not already regenerated, and the trial has not ended. The dashboard's
button reads it, and `DailyKindSwap` reads it plus "nothing submitted" before
offering its "Want it in today's set?" line, so the two cannot drift. The line
is stricter than the button on purpose: the button still shows on a submitted
but unreviewed set, and offering a swap's "apply it today" there would mean
throwing away submitted work.
