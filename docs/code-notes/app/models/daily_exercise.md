# app/models/daily_exercise.rb

## `#with_response_locked`

Every writer that touches both rows takes the exercise first, then the
response: `RegenerateExerciseJob`, `User#carry_forward`, `#start_over!` and
`ResponsesController#save_answers_under_lock`. One order means two of them
wait for each other instead of deadlocking.

Before either, it takes a `FOR SHARE` lock on the owner's `users` row. The
first autosave of a day inserts a `daily_responses` row, and that insert
needs a key-share lock on the user through the foreign key. `AccountDeletion`
holds the user `FOR UPDATE` and then waits for the exercise, so an autosave
that held the exercise and then waited for the user deadlocked with it.
Taking the user first puts every caller in deletion's order: user, exercise,
response. A caller that already holds the user `FOR UPDATE` loses nothing,
since a transaction can share-lock a row it already holds. When deletion
wins, the exercise is gone and `#lock!` raises `RecordNotFound`.

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
ingests (which includes `CodeFormat`, whose Prettier
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

## `#draft_scope` and `#freshness_against`

A draft scope names one write of one set and its answer-reset revision:
the row id, a hyphen, and `generated_at` in microseconds, with `-rN` appended
after a Start over. `N` is the server-owned `plan_notes["draft_revision"]`;
an absent key means zero and keeps the original scope format. A regeneration updates the row in place
(`PracticeGeneration.commit_replacement`), so the id stays and the time
moves. The format is written and read only here: `DRAFT_SCOPE_FORMAT` is the
pattern, and the private `#written_stamp` is the time part.

A non-Hash `plan_notes` also reads as revision zero, with one content-free
warning per scope read. This keeps the scope reader usable without changing
stored metadata. It is not general support for malformed historical notes:
other existing readers require a Hash, and canonical writers supply one.

`#freshness_against(scope)` compares the set with the scope an open page
shows and names the result, so a caller never has to combine checks in the
right order:

- `:current` when the scope is this set's own, and also while the set is
  regenerating, whatever the scope. A page that reloaded then would land on
  the generating panel, so the set holds its answer until the rewrite is
  finished.
- `:replaced` when the scope names this row and an earlier write of it.
- `:stale` for everything else.

A page sends the scope back as a parameter, so the rewrite test (the private
`#rewritten_since?`) accepts only a value that matches the pattern. Blank, an
array, extra parts and a trailing newline are `:stale`, and so are another
row's scope and a time later than the stored one. A reset with the same
generation time is `:stale`, not `:replaced`: the problems did not change.
The pattern also accepts a reset suffix on an older generation, so a later
regeneration still reports `:replaced`.

## `#start_over!`

Start over uses `#with_response_locked` for the whole operation: check that
the response still has the requested id, recheck `#replace_blocker` and the
date, empty the duck thread, destroy the response and advance the reset
revision. Those writes commit together. A failed write rolls all of them
back. A delayed second reset cannot delete a new response created after the
first reset.

Before the destructive steps, `#validate_reset_notes!` rejects non-Hash notes
with `ActiveRecord::RecordInvalid`. The controller logs the record class and
invalid attribute names, never their contents, then redirects with a failure
alert. It does not normalize or discard the stored notes.

The answer endpoint already reloads the exercise and checks scope under the
same locks before finding or creating a response. If its save wins first,
reset deletes the saved answer; if reset wins first, the old scope gets a
409 before any answer write. Duck append and Clear recheck scope there too,
including a first reply for which no thread row existed at reset time.

The revision belongs in the exercise's existing server-owned metadata,
not in the generated problem content or the duck thread. No migration is
needed. Using `generated_at` would falsely report a new generation and
disconnect `JudgeSolve` rows from their set. Using the response's draft
token would reject ordinary consecutive saves and cannot distinguish a page
loaded before the first response existed from an empty page after reset.
Opening the set, saving answers and using the duck leave the revision alone;
carry-forward preserves it. Regeneration replaces the plan notes and changes
`generated_at`, which already invalidates every previous scope.

Old web binaries ignore this revision. Mixed-version writers and rollback
therefore restore the previous late-save limitation; the local probe and
upgrade caveat are recorded in
`docs/decisions/idempotent-saves-and-frozen-evidence.md`.
