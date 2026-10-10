# app/controllers/daily_exercises_controller.rb

## `#generate`

The action carries a held set forward before it checks whether today has a set. Checking first would find no set, enqueue a generation, and bill a provider call whose result the unique index on `[user_id, date]` then throws away.

It clears today's earlier generation failure before enqueuing, so `/dashboard/status` doesn't report "failed" while the retry runs.

## `#regenerate`

The claim passes `regenerated_at: nil`, the once-per-day gate. When the job can't be enqueued, the action releases its own claim, so nobody waits behind a spinner that never clears.
