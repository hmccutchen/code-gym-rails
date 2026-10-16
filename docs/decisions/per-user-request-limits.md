# Per-user request limits

they guard a trial's house key, so an account
with a key of its own is never held to them (`ApplicationController#own_key?`,
the `unless:` on each limit below). Every endpoint that bills one provider
call (`ResponsesController`'s duck, follow-ups, explain
differently and pseudocode critique, and
`ConceptReferencesController#explain_differently`) declares
`ProviderCallLimits`, which counts them together: `ProviderCallLimits::HOURLY`
(60) per user per hour and `DAILY` (300) per day, in one fixed scope so the
count is shared across both controllers. Each endpoint's own per-section or
per-page cap still applies; the shared count runs before every other check,
so a request those checks refuse still counts. `/generate` allows
`DailyExercisesController::GENERATE_PER_HOUR` (3) and the three Learn
prepare actions `LearnController::PREPARE_PER_HOUR` (10) presses an hour.
Those per-endpoint caps and the job permit below apply to every
account. `GenerateDailyExercisesJob` holds one Solid Queue concurrency permit per
user and discards an overlapping enqueue, because every dashboard load with
no set enqueues one and each would run a full billed generation before the
unique index threw it away; the hourly batch passes no user and is not
limited. These are starting values, not measured ones. All of them use
`LazyCacheStore`, so the test env's `:null_store` never trips them and a
spec that exercises one swaps in a real store.
