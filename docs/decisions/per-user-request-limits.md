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
Those per-endpoint caps and the generation claim below apply to every
account. `GenerateDailyExercisesJob` takes a claim on its user
(`users.generating_since`, declared with `Claimable`) when it starts running
and releases it when it ends, because every dashboard load with no set
enqueues a job and each would run a full billed generation before the unique
index threw it away. A job that finds the claim held logs one line and stops
before any provider call, and a job that takes it stops when today's set is
already there. The hourly hand-out (`EnqueueDueGenerationsJob`) generates
nothing itself: it enqueues that same per-user job for each due user, so the
claim covers a scheduled generation and a dashboard-started one alike. The
claim goes stale after `CallProfiles::JUDGED_GENERATION_BUDGET` seconds, so a
worker that died mid-call blocks its user for that long and no longer.

The claim replaced a Solid Queue concurrency permit (`limits_concurrency`
with `on_conflict: :discard`). Solid Queue takes that permit when a job is
enqueued, which went wrong in three ways once scheduled jobs waited in a
queue. The permit expired a budget after the enqueue even with the job still
waiting, and a second job could then be enqueued and both could bill. A
dashboard click was discarded while the scheduled job was only queued, so the
person waited for their place in the morning queue. And a paused user's
"generate anyway" was discarded in favour of a scheduled job that then saw the
pause and did nothing, leaving the dashboard polling for the whole budget. A
claim taken when the job runs has none of these: a click always gets a job
of its own, which runs ahead of the scheduled ones
(`EnqueueDueGenerationsJob::SCHEDULED_PRIORITY`).

What a job writes after its paid call is checked again under the user row
lock. `PracticeGeneration.commit_new` writes the set only when the day has
none, whoever holds the claim by then, since a finished set is worth keeping
either way. A failure is written only while the job still holds its own
claim: one that overran the budget and was taken over leaves the outcome to
the job that took it.

A duplicate job is no longer discarded, so it waits in the queue and then
stops at the claim or at the existing set. One case costs more than it did:
a duplicate that starts after the first job failed finds no claim and no
set, and generates again. These are starting values, not measured ones. All of them use
`LazyCacheStore`, so the test env's `:null_store` never trips them and a
spec that exercises one swaps in a real store.
