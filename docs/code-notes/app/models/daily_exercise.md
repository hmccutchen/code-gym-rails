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
