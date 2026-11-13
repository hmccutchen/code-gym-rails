# Per-user request limits

These limits guard a trial's house key, so an account
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
`DailyExercisesController::GENERATE_PER_HOUR` (3) presses an hour.
A bulk press (`prepare`, `prepare_ladders`) enqueues its jobs at
`JobPriority::BACKGROUND` (20): behind a dashboard click and the
single-concept write-up a person waits on (`JobPriority::CLICK`, 0, the
default), and behind scheduled sets (`JobPriority::SCHEDULED`, 10). One
press can queue about 90 jobs, and at 0 they held up a click made after it;
until L3b of `docs/decisions/learn-content-per-user.md` they ran at 5, ahead
of the scheduled sets. `JobPriority` is the one place the priority numbers
live.
The three Learn prepare actions have no hourly cap. The one they had
(`PREPARE_PER_HOUR`, 10 presses an hour) skipped accounts with a key of their
own, and since L2 of `docs/decisions/learn-content-per-user.md` a trial
account on the house key writes no Learn content, so the cap reached only
presses refused before anything was queued. It was removed as dead code
(#792).
Saving a key in Setup allows `ApiKeysController::KEY_SAVES_PER_HOUR` (10)
saves an hour per account and `KEY_SAVES_PER_HOUR_BY_IP` (30) per address.
Each such save asks a provider about the key
(`docs/decisions/per-user-api-keys.md`), so without a cap the form would
test keys for anyone. It counts only a save that carries a key, and it
applies to own-key accounts too, since it guards other people's keys and
not the house key.
These caps are starting values, not measured ones. All of them use
`LazyCacheStore`, so the test env's `:null_store` never trips them and a
spec that exercises one swaps in a real store.

The key-save caps and the generation claim and permit below apply to every
account; the `/generate` cap skips an account with a key
of its own, like the shared provider-call count. `GenerateDailyExercisesJob` takes a claim on its user
(`users.generating_since`, declared with `Claimable`) when it starts running
and releases it when it ends, because every dashboard load with no set
enqueues a job and each would run a full billed generation before the unique
index threw it away. A job that finds the claim held logs one line and stops
before any provider call, and a job that takes it stops when today's set is
already there. The hourly hand-out (`EnqueueDueGenerationsJob`) generates
nothing itself: it enqueues that same per-user job for each due user, so the
claim covers a scheduled generation and a dashboard-started one alike. The
claim goes stale after `User::GENERATION_STALE_AFTER`, so a worker that died
mid-call blocks its user for that long and no longer. That window is
`CallProfiles::JUDGED_GENERATION_BUDGET` plus `DailyExercise::WRITE_MARGIN`.
The budget counts provider calls only, while the capture before them and the
ingest, formatting and commit after them also run under the claim, so without
the margin a worst-case job would find its own claim stale just as it wrote.
The dashboard's poll limit reads the same constant. The permit keeps the
bare budget as its duration.

The job also holds a Solid Queue concurrency permit (`limits_concurrency`
with `on_conflict: :discard`), and the two have separate roles. The permit
keeps the same request from being queued twice: its key is `click/<user id>`
for a dashboard job and `scheduled/<user id>` for a hand-out job, so a second
click is discarded while the first click's job is queued or running, a second
hand-out run leaves one scheduled job, and neither kind ever discards the
other. The claim decides which running job may generate.

One permit per user once did both jobs, and Solid Queue takes a permit when a
job is enqueued, which went wrong in three ways once scheduled jobs waited in
a queue. The permit expired a budget after the enqueue even with the job still
waiting, and a second job could then be enqueued and both could bill. A
dashboard click was discarded while the scheduled job was only queued, so the
person waited for their place in the morning queue. And a paused user's
"generate anyway" was discarded in favour of a scheduled job that then saw the
pause and did nothing, leaving the dashboard polling for the whole budget. A
claim taken when the job runs, beside a permit a click does not share with a
scheduled job, has none of these: an expired permit only lets a duplicate be
queued, which the claim then stops, and a click always gets a job of its
own, which runs ahead of the scheduled ones
(`JobPriority::SCHEDULED`). A discarded `perform_later`
returns false and raises nothing, so the hand-out moves on to the next user.

What a job writes after its paid call is checked again under the user row
lock. `PracticeGeneration.commit_new` writes the set only when the day has
none, whoever holds the claim by then, since a finished set is worth keeping
either way. A failure is written only while the job still holds its own
claim: one that overran its window and was taken over leaves the outcome to
the job that took it.

Two sequences can still bill a second attempt on a day the first one failed,
because a job that starts after a failure finds no claim and no set. A click
and a scheduled job for one user are both queued, the first to run fails, and
the other then generates. Or a click's job waits in the queue past its
permit's expiry, a later dashboard load queues a duplicate, the first fails,
and the duplicate generates. Both are retries one after the other, never two
calls at once.

The hand-out enqueues a job each hour for a due account with no set, so a
morning failure is tried again an hour later. Two things bound that. An
account whose key was rejected, or that ran out of credit, twice in a row
leaves `ScheduledGeneration.users` until its owner starts a generation that
works or saves a key. An account whose last three sets went unopened is
paused. `docs/decisions/pausing-generation.md` has both rules.
