# One finish action

Today has one Submit button in normal document flow near the exercise and Add
controls. The desktop side layout can keep it alongside the exercise, and
the mobile layout keeps inputs and the virtual keyboard clear of overlays.
Today shows section statuses and hint locks from the server and omits the
section quota. Submitted and historical views keep their existing layout.

`DailyResponse#submit_blocker` is the sole authority for submission validity.
At least one section must count as answered, and every answered section must
have a rating. The form renders the server's initial readiness. Each answer
or rating edit disables Submit immediately, including edits restored from a
local draft. A reply enables the action only if it confirms the current edit
sequence with a nil blocker and there is no pending or failed answer save,
generation or addition in progress, stale set or manifest, or
submission already under way. Each autosave reply carries the blocker,
answered sections, section statuses, draft scope and manifest revision. The
browser uses the server's answer for the nudge and section state.

Typing saves 800 ms after the last keystroke. Selecting or clearing a rating,
leaving an answer, choosing a comparison option or moving a Parsons block
saves at once. In a draft rating payload, an explicit JSON null clears the
rating, omission preserves it, and invalid values are ignored. Choosing a
selected rating again clears it. Answer edits preserve ratings unless
explicitly cleared. Partial answer payloads merge into the draft, and
explicit empty strings clear answers. Submit keeps ratings only for counted
answers, and submitted ratings are immutable.

Pending answer saves keep Submit disabled. After a click, the form flushes
and awaits a pending note before posting the submission. The server
revalidates the draft scope, manifest revision and readiness under lock. `ResponsesController#create` refuses an invalid
submission with a 422 carrying the nudge sentence, answered sections and the
blocker. Nothing from the refused request is saved. The page shows that
sentence and moves focus to it. An accepted submission freezes the snapshot
and counts toward the streak. The same click starts the separate review
request, with one review per day, and a repeated submit returns the existing
review URL. The existing navigation gate waits for other queued saves before
leaving the page. The form stays inert through submission and review handoff.

A refused or dropped submission restarts the draft autosave it canceled, so
the last edit survives without another keystroke. A submission that got no
reply restarts it too, since the server may have committed the submit and
lost only the reply; that autosave then reloads into the submitted page. If submission succeeds but
the browser cannot start the review POST, the page explains that the answers
were saved and reloads the submitted state with its manual review button.
It keeps the acknowledged submission in the submitted state.

PR3 is stacked on PR2 by owner approval so readiness can use the existing
addition coordination. Its scope is Today, draft ratings and readiness.
It uses the existing schema, provider calls and scheduler, and ships
without a feature flag. Recall is handled in a separate PR.
