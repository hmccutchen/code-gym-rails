# app/services/exercise_addition_request.rb

## Acceptance and replay

One UUID identifies one accepted operation within a daily exercise. Admission
checks the shown scope and current set before replaying a prior UUID; replay
keeps the original kind and does not create or enqueue another operation.
Fresh requests also check the manifest revision, submission, regeneration,
active additions, provider readiness and the shared available-kind policy.
Acceptance and worker revalidation are separate checks of the same policy:
settings or the set may change while a queued job waits.

## Locks and recovery

The exercise advisory lock comes before the owner, exercise, response and
addition row locks. `with_locked` takes the owner exclusively, then uses
`DailyExercise#with_response_locked` for the exercise and response. Provider
work happens outside those row transactions; the worker retains advisory
ownership so recovery cannot overlap its paid attempt.

`recover!` first checks whether an active operation has expired. Ordinary
Submit, Start over and regeneration requests do not take the advisory lock
when there is nothing to recover, so they cannot make a newly starting worker
lose its nonblocking claim. An expired candidate still needs advisory
ownership and an expiry recheck under row locks before becoming failed.
Elapsed time alone never permits a second worker to execute the operation.

## Enqueue and failure ownership

The controller supplies the enqueue callable. It runs after all enclosing
transactions commit, so the service does not depend on a job class and a
worker cannot see an uncommitted request. Enqueue failure marks only the
still-unclaimed queued operation failed.

`fail!` changes only the matching running claim. Its optional block receives
the freshly locked user only when that failure write succeeds, allowing the
worker to record provider failure status without a stale worker overwriting
newer state. The service returns named outcomes; the controller explicitly
maps them to HTTP replies and raises for an unknown outcome.
