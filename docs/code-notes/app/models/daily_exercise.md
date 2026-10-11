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

It selects the response dated with the exercise, as `#current_response` does
for a read without a lock; `#dated_response` is the one query both use. `daily_exercise_id` is not
unique, and legacy carry-forward data can leave an older response on the same
exercise; locking that one would let `RegenerateExerciseJob` miss today's
reviewed response and replace the set under it.
