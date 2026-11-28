# app/controllers/daily_exercises_controller.rb

## `#generate`

The action carries a held set forward before it checks whether today has a set. Checking first would find no set, enqueue a generation, and bill a provider call whose result the unique index on `[user_id, date]` then throws away.

It clears today's earlier generation failure before enqueuing, so `/dashboard/status` doesn't report "failed" while the retry runs.

## `#regenerate`

The button posts the page's `draft_scope`, and `#set_to_regenerate` refuses with `regenerate_stale` before anything moves unless the scope names one of the user's sets exactly (`CurrentSetLookup#shown_set_at`, the same id read and exact comparison autosave uses). A missing scope is refused the same way. Only then, with `HELD_SET_LOOKUP` on, does it carry the held set forward, and only when that is the shown set (`User#carry_held_set_forward!(only:)`), as Start over does. The move clears `regenerated_at`, as a dashboard load does. With no set for today after that it redirects with `nothing_to_regenerate`, worded for a page whose set is no longer current. When today's set is a different set from the one shown, as on an unpaused tab left open overnight, it refuses with `regenerate_stale`, so a stale tab never replaces a set it didn't show or destroys a held set's draft.

The claim is taken by `DailyExercise#claim_regeneration!`, which checks the posted scope again under `#with_response_locked` (user, then exercise, then response) and takes the claim in that same lock. A Start over that lands between the first check and the claim advances the draft revision, so the second check refuses with `regenerate_stale` and nothing is claimed; without it, the job would replace the reset set and delete the draft typed after the reset, since `PracticeGeneration.commit_replacement` checks the claim and the settings but not the scope. The same lock checks `DailyResponse#replace_blocker`, and the claim passes `regenerated_at: nil`, the once-per-day gate. When the job can't be enqueued, the action releases its own claim, so nobody waits behind a spinner that never clears.

Before claiming regeneration, the action asks `ExerciseAdditionRequest` to
recover an expired addition. Recovery checks for an expired candidate before
trying its advisory lock. `claim_regeneration!` then independently refuses an
active addition under the exercise/response locks, so Add cannot start between
an unlocked check and the destructive claim. The action maps that refusal to
the addition-in-progress message.
