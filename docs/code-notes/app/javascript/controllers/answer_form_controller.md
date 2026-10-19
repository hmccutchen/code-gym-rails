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
replaced by every autosave reply. The controller never judges an answer
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

The "One finish action" decision (`docs/decisions/one-finish-action.md`) says the Submit button is always clickable,
and it still is. A click before the module loads is lost the same way a rating
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

Submit is always clickable, and the payload reads each section's hidden
field. A kind whose answer only reaches that field through its own controller
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
can be retried, and Submit is disabled. When the gate holds,
`holdForOtherSaves` applies the same freeze (to a submit's form too) and adds
a notice with a Reload button. When the armed leave finally runs, `relockAndLeave`
makes the whole form inert again, swap rows included, so no new swap can be
queued while the review POST or the reload is on its way. The leave stays armed in `save_status`: once the
retried save lands, the held submit goes on to the review, and a held
autosave reload reloads. The `answers` and `submit` keys are ignored,
because the submit carries every answer. `docs/code-notes/app/javascript/code_gym/save_status.md`
lists which paths use the gate and which deliberately don't.

## The copy on the device

Every edit writes the answers and ratings to `code_gym/draft_store` with the
draft token the copy was built on: the one the server rendered, or the one the
last save reply carried. On connect, `restoreDraft()` puts a copy back only
when its token equals the page's token, meaning the server's saved answers are
still exactly the ones the copy started from. Anything else (another day, a
regenerated set, a Start over, a save from another tab or device) deletes it.
The token is a digest of the saved answers and ratings, not `updated_at`,
because a pseudocode round writes the same row without touching the answers.

A restored field is skipped when its value already differs from what the
server rendered, since that is text typed before the controller connected.
A field marked `data-draft-restore="off"` is never restored, so a kind opts
out in its own answer partial rather than here. Parsons does: its blocks are
rendered in the server's order, and each move saves at once. A restored design comparison is told through the
bubbling `answer-form:restored` event, and its own controller also checks on
connect, because either controller can connect first.

`settleDraft()` clears the copy when a save reply arrives for exactly the
answers on screen, comparing answers and ratings with their keys sorted, like
the server's digest, since two tabs can insert the same ratings in different
orders, and otherwise rewrites it on the reply's token, so later
edits stay kept. `nextSave()` records what each attempt sent, because the
queue reads the body again on every retry. A submit, a stale refusal and a
reload into the submitted page all clear it.

When a save reaches the server but its reply is lost, and the page is killed
before a retry, the next load renders a token the copy does not have. The copy
is dropped and the server's draft shows. That draft holds the save that got
through, so what is lost is limited to the edits made after it.

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
when the last write to `draft_store` succeeded (`draftKept`). With storage
blocked or full, the retry shows the generic failure and an offline submit
the generic submit failure.

## Clearing another tab's copy

Every tab on the dashboard shares one stored copy. A save reply clears it only
when the stored copy holds exactly what that save sent, and a stale refusal
clears it only when the stored copy carries this tab's token, so an old tab
cannot delete what a newer one wrote. A successful submit, and a reload into
the submitted page, clear it whoever wrote it, since the day is finished.
