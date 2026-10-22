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

The window is `REGENERATION_DEADLINE`, the deadline the job runs under
(`GenerationDeadline`, measured from the claim), plus `WRITE_MARGIN`. That deadline is one
worst-case judged pass plus `JOB_PICKUP_MARGIN`: the draft call, which retries
a 429 or 5xx after a full 300 s read (946 s), then one judge call (181 s), plus
the 60 s the old six-minute value allowed for a worker to pick the job up. It
comes to 1,187 s, about 20 minutes. The deadline refuses any call whose worst
case would end after it, so no healthy job outlives the claim, and a judged
day's full budget (2,302 s) never has to fit in the window.

The deadline bounds provider calls only. After the last one, the job still
ingests (on the single-stage path that includes `CodeFormat`, whose Prettier
run is capped at `CodeFormat::Javascript::TIMEOUT_SECONDS`, 20 s), writes the
`ExerciseDraft.finish` diagnostics, waits for the response and exercise locks
behind any autosave or submit, and updates the row. If the claim went stale in
that gap, a second click could take it and the first job would discard its
billed result. `WRITE_MARGIN`, 60 s, covers that work three times over at
Prettier's cap; it is a margin, not a measured figure. The window comes to
1,247 s, about 21 minutes. The cost is that a worker which dies mid-call keeps
`/regenerate` refused, and the page on its generating state, for that long.

The generating poller sizes its attempts from the larger of this window and
`CallProfiles::JUDGED_GENERATION_BUDGET`, so it keeps polling for the whole
window.

## `#regeneration_offered?`

The regenerate button's three conditions: the response is not reviewed, the
day has not already regenerated, and the trial has not ended. The dashboard's
button reads it, and `DailyKindSwap` reads it plus "nothing submitted" before
offering its "Want it in today's set?" line, so the two cannot drift. The line
is stricter than the button on purpose: the button still shows on a submitted
but unreviewed set, and offering a swap's "apply it today" there would mean
throwing away submitted work.

It deliberately differs from `DailyResponse#replace_blocker`, which also
refuses while a review is in flight. The swap design keeps the button as it
was, so its three conditions moved here unchanged. `replace_blocker` stays the
authority on whether a regeneration is accepted: a click during a review that
is still running is refused by `/regenerate`, and the button is right again
once the review lands.
