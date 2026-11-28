# app/javascript/controllers/answer_form_controller.js

## What it owns

The dashboard's answer form: autosave, the progress bar, the hint lock, the
self-rating buttons, the submit nudge, and the submit-then-review chain.

## The controller wraps the form, not the form alone

The progress bar sits above the form in the markup, outside it, so the
controller's element is a wrapper around both and the form itself is a target.
Everything that reads the form's own contents goes through `formTarget`, which
is also what `inert` is set on.

## The server decides; the page shows its answer

`answeredSections` and `submitBlocker` arrive as Stimulus values and are
replaced by eligible autosave replies. A reply that predates pending edits
does not replace the live state. The controller never judges an answer
itself. That rule is the project's, not this file's, and it is why the
progress count, the hint lock and the nudge all read the same two fields.

## The submit button is not a submit button

`javascript_importmap_tags` emits a module script, which is deferred, so there
is a window between the page rendering and this controller connecting. The
form's textareas carry real `name` attributes and the form posts to a real
endpoint, so a `type="submit"` click in that window would natively submit the
day and land the browser on raw JSON. The button is `type="button"` instead,
and its click reaches the controller as an action. No other control in the
form can submit it natively either: the rating buttons are `type="button"` too
and an answer field is a textarea, where Enter inserts a newline.

The form still carries `submit->answer-form#submit`. Nothing dispatches that
event today, and the action exists so a field added later cannot post the day
around this controller.

The "One finish action" decision (`docs/decisions/one-finish-action.md`) keeps validation feedback on Submit rather than maintaining a second browser
readiness rule. Submission or a pending addition can still disable the action
while the corresponding work is in flight. A click before the module loads is lost the same way a rating
click is, and clicking again works.

## Delegated listeners

Input, change and rating clicks are Stimulus actions on the form rather than
listeners bound per element. The Parsons and design-comparison answer scripts
write their hidden textarea and dispatch a bubbling `input` event, which is
what makes delegation equivalent to the per-textarea binding it replaces.

## An answer typed before the controller connected

The modules are deferred, so a user can type into a textarea while the page is
still only parsed HTML. No `input` event survives to `connect()`, so without a
check the answer would sit in the field unsaved until the user touched it
again.

`connect()` therefore compares each textarea's `value` with its
`defaultValue`. A textarea's `defaultValue` is its server-rendered content
exactly, so any difference means someone typed in the gap, and the controller
schedules a save the same way an `input` event would. `code_gym_bootstrap.js`
covers the other half — it keeps `pending()` true across that gap so
pull-to-refresh cannot reload over the edit — and its code note has the whole
picture.

`spec/system/deferred_module_spec.rb` stalls the module assets, types an
answer, and expects it saved. Without the `defaultValue` check no save is ever
scheduled, so the example times out.

## Submit waits for the page's controllers

A permitted Submit click reads each section's hidden field. A kind whose answer only reaches that field through its own controller
— the design comparison's pick and reason — would post the previous answer if
the click landed before that controller connected. So `submit()` awaits
`CodeGymBootstrap.ready`, which resolves once every controller on the page
has connected and the early-edit recorder has been settled. The click is
deferred, never dropped.

`ready` is not proof that they connected, though. It gives up after a timeout
(`app/javascript/application.js`) so that an early edit cannot stay pending
for the life of the page, and a module that fails to load or takes longer than
that would then leave its hidden field stale. So once `ready` settles,
`submit()` checks every controller inside the form itself. If any is missing,
it posts nothing, shows `dashboard.exercise.controls_not_ready` in the save
banner and gives the form back. The check covers every controller in the form,
not only the ones that write a hidden field, because a module that never
arrived means the page needs a reload either way. A later click submits once
the module has connected. `spec/system/deferred_module_spec.rb` answers the
missing comparison module with a 404 and expects the stale pick to stay
unsubmitted.

## Submit waits for the latest note save

The learner-note box sits inside this controller's wrapper but outside
`formTarget`, so its text never joins the answer payload. Once the modules
are ready, `flushPendingNote` asks that box's controller to flush any pending
typing timer and await its latest queued or in-flight save before posting
Submit. An ordinary autosave that already failed is retried once with the
latest text, including an empty string. Waiting only at the later leave gate
would let Submit close the day before the note could save. A missing note
controller uses the existing controls-not-ready message; no note box means
no extra save.

`lockForSubmit` makes the note inert too, so a new edit cannot appear while
the flush is running. A 409 returned by the flush takes the existing
stale-page path without posting answers: the banner below may take it, and
otherwise the page reloads. A completed autosave's 409
is reused without another PATCH only when no new edit is pending; editing
still schedules a save. The leave gate ignores that note conflict, but
still waits for unrelated saves and failures; the form stays locked until
recovery. Other failed flushes call the existing `unlock`,
restoring both the answer form and the note with its text and error intact.
A save that fails while Submit waits is not retried by that same click.
The note controller retains the latest pending promise and its result, so
an older reply cannot clear a newer failure or lose a pending edit. The next
explicit Submit retries a failed save; a successful, unchanged note needs
no new save. The shared queue still owns request ordering and error display.
An already-submitted refusal from another tab, including one cached from a
completed autosave, is settled without retrying unchanged text; the server
keeps the note read-only.

The account's notes setting can change while this page stays open. Its real
404 follows the failed-flush path: each explicit Submit retries once, keeps
the note text and error, and leaves answers unsubmitted. `unlock` resumes
ordinary answer autosaving. A persistent refusal is not bypassed. A manual
reload reads the new setting and removes the box, losing its unsaved text.
The missing-exercise 404 takes the same path.

If the note request never settles, neither does the flush: Submit stays
disabled, both boxes stay inert, and no answer POST begins. `request.send`
has no application timeout or cancellation; this controller adds none.
The browser regression holds and releases a request to verify the ordering,
without measuring browser or network timeouts.

## A stale refusal under the out-of-date banner

Before an autosave's, a submit's or the submit's note flush's `409 stale`
reloads the page, the form raises a cancelable `code-gym:stale-save` window
event carrying the reply's `banner` sentence and the keys to leave out of
the unsaved check: `answers` for the autosave, `submit` and `learner_note`
for the note flush. `fresh_day_controller` cancels it under `STALE_SET_BANNER`
when `saveStatus.unsaved()` holds or its banner already shows, and shows the
banner. The form then clears its own draft copy and stops autosaving
(`stopSavingBehindBanner`), so unsent duck or explanation text stays on the
page until the person presses the banner's button. A refused submit, or
a refused note flush, is reported under `submit` and the form unlocks, as a
not-current submit is.
When nobody cancels the event, which is always the case with the switch
off, the reload below runs as before.

The banner's "Reload and discard changes" raises `code-gym:discard-draft`
right before it reloads, and `#discardDraft` clears the copy this tab owns.
Without it, a refused edit to a held set that the reload carries forward
under the same scope and token would be restored and autosaved by the
reloaded page.

## Leaving the page waits for other saves

Every way the form leaves the page by itself goes through
`saveStatus.settled`: the submit, before it starts the review or reloads
after a 409, and the autosave's two reloads, for a 409 saying the set
changed and for a reply saying another tab submitted. Another control may
still have a save queued, such as a daily card's swap waiting behind the
other card's, or a save that failed and is waiting for a retry; leaving
would drop it. When nothing is pending and no other key has a failure,
`settled` resolves at once, so a normal submit leaves as before.

Each of those leaves goes through `leaveWhenOtherSavesLand`, which sets
`submitHeld` first, so `autoSave` and `sendSave` do nothing from then on, and
the reply to an autosave already on the wire is ignored, so a late
`submitted: true` can't start a reload that competes with the armed leave: the
page is about to leave, and the server would ignore an edit to a submitted
response or one for a replaced set. It also calls `freezeAnswers` at once,
before the gate answers, unless the form is already inert from a submit:
every answer, rating and section control becomes `inert`, so no edit can be
made during the wait and then dropped by the leave. Each section's summary
and the daily cards' swap rows stay usable, so the save that blocks the page
can be retried, and Submit is disabled. Generate new set and Start over
(`replaceButton` targets) are disabled too, here and in `lockForSubmit`, and
`unlock` turns them back on: they sit right beside Submit in the side column,
and either one, landing after the submit commits, would replace or delete the
day just submitted. When the gate holds,
`holdForOtherSaves` applies the same freeze (to a submit's form too) and adds
a notice with a Reload button right after the form, in the main column, then
scrolls it into view, since it lands at the end of the answers, often below
the screen. It sits with the answers rather than in the side column, so on a
desktop it stays beside the frozen form it explains. When the armed leave finally runs, `relockAndLeave`
closes any open dialog in the form first (a daily card's swap sheet), then
makes the whole form inert again, swap rows included, so no new swap can be
queued while the review POST or the reload is on its way. The close comes
first because a modal dialog inside a subtree that turns inert would stay on
screen with nothing in it reachable. The leave stays armed in `save_status`: once the
retried save lands, the held submit goes on to the review, and a held
autosave reload reloads. The `answers` and `submit` keys are ignored,
because the submit carries every answer. `docs/code-notes/app/javascript/code_gym/save_status.md`
lists which paths use the gate and which deliberately don't.

## The copy on the device

The copy of the unsent answers, and every rule about when it is restored,
rewritten or cleared, live in `code_gym/draft_store`'s `DraftCopy`; its code
note has them. The controller builds one on its first connect and calls
`reconnect()` on it on every later connect, each time with the token and
draft scope the server rendered, and hands it plain data: the answers and
ratings on screen (`onScreen()`) on every edit and every save attempt, and
the ones the server rendered (`rendered()`, the textareas' `defaultValue`)
when it connects. The rendered values also carry the server-computed empty,
unrated persisted baseline used for appended-field recovery; display scaffolds
do not become a client-side answered rule. The controller keeps the parts
that touch the page.

`restoreDraft()` asks the copy for the stored answers and ratings it may
restore and puts them into the fields. A restored field is skipped when its value already differs from
what the server rendered, since that is text typed before the controller
connected. A field marked `data-draft-restore="off"` is never restored, so a
kind opts out in its own answer partial rather than here. Parsons does: its
blocks are rendered in the server's order, and each move saves at once. A
restored design comparison is told through the bubbling
`answer-form:restored` event, and its own controller also checks on connect,
because either controller can connect first.

When the restore kept an edit typed before the controller connected, a field
whose value differs from both what the server rendered and the copy, the
screen is this tab's own, so `restoreDraft()` doesn't hand the copy's list of
unconfirmed saves to the page. A field the restore never touches, such as
Parsons, doesn't count, since the copy's list is still the saves of the
answers it restored.

`storeDraft()` writes nothing while the form is inert, during a submit or a
leave. `nextSave()` records each attempt with the copy, because the queue
reads the body again on every retry, and `settleDraft()` hands an ok reply's
token to it and rewrites the copy when the answers on screen moved on during
the save.

## Submitting offline

A submit that got no reply shows `submitOffline` instead of the generic
failure and leaves Submit enabled. It still restarts the autosave, because no
reply can also mean the server committed the submit and only the reply was
lost; that autosave comes back `submitted: true` and reloads into the
submitted page. While the connection is down, that autosave's retry carries
the same `submitOffline` sentence (`offlineSentence()`, read on every failed
attempt, so a retry already waiting when Submit fails switches too), so the banner keeps
saying the answers were not submitted rather than switching to the
saving-offline one. The first save that lands clears both. A submit is never
queued: it saves the answers and returns the review URL, and the page then
posts that URL as a separate request that starts the billed review, so a
queued submit would start a review later, out of the user's sight.

Both sentences promise the answers are kept on this device, so they show only
when the last write to `draft_store` succeeded (the copy's `kept`). With storage
blocked or full, the retry shows the generic failure and an offline submit
the generic submit failure.

## Clearing the copy

A stale refusal clears the copy only if this tab owns it (`clearOwn`), and an
ok save reply clears it inside `settle`; `draft_store.md` says why both leave
a newer tab's copy alone. A successful submit, and a reply saying the day is
already submitted, clear it whoever wrote it (`discard`), since the day is
finished.

## Incremental additions

`reconcileStructure` checks scope, revision and submission state before
inserting missing section cards. It preserves existing nodes, input values,
ratings, folds and duck drafts. Each newly inserted key adopts only its own
server-computed answered membership and rendered rating before progress and
teaching-hint locks are refreshed. It does not replace the answered state of
existing live inputs with a status poll's older snapshot. An autosave reply
from an older manifest also cannot replace that state. When no newer save is
queued or scheduled and the form is still editable, it schedules an autosave
of the expanded form so the server recomputes answered state. Stale and
submitted replies keep their existing leave paths before this check.

The controller rescans answer fields and advances the manifest revision only
after the cards are present. `code-gym:sections-added` lets the existing
Mermaid and code-lines controllers initialize their new descendants. Add
requests and new submissions carry the current revision as well as scope.
A `manifest_changed` or `addition_busy` submit reply unlocks the form,
refreshes additions and shows the refusal without discarding drafts,
reloading or submitting again.

`additionState` disables Submit and replacement controls while generation is
pending. A held submit keeps the sections wrapper itself non-inert so Swap
recovery controls remain reachable; the existing traversal still makes each
section's answer content inert. The sibling Add picker remains locked during
that hold. Reconciliation never reconnects the whole form or replaces its
DraftCopy.
