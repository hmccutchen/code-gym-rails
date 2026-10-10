# app/controllers/daily_exercises_controller.rb

## `#generate`

The action carries a held set forward before it checks whether today has a set. Checking first would find no set, enqueue a generation, and bill a provider call whose result the unique index on `[user_id, date]` then throws away.

It clears today's earlier generation failure before enqueuing, so `/dashboard/status` doesn't report "failed" while the retry runs.

## `#claim_regeneration!`

One `UPDATE ... WHERE` claims the regeneration atomically and enforces the once-per-day gate (`regenerated_at` is nil). A claim older than `DailyExercise::REGENERATION_STALE_AFTER` can be taken again.
