# app/views/dashboard/_exercise.html.erb

## Reviewed hint

Hiding the Generate new set button once the response is reviewed mirrors the
guard in `DailyExercisesController#regenerate`, which is the one that holds.
The review is already part of concept tracking, and a new set would discard
it.

## Generate new set button

`turbo_confirm` would do nothing here, because Turbo JS is not loaded. The
layout's loading-form script provides the confirmation and the in-flight
spinner. The request then blocks on the provider (10 to 30 seconds) until the
redirect lands.

## Progress bar

The progress bar is sticky so progress stays visible while scrolling through
the sections on small screens.

## Answer form

The form always POSTs, never PATCHes: `ResponsesController#create` serializes
saves and repeated submits under the response lock. The controller sends both
through fetch.

## The controller

`data-controller="answer-form"` wraps the progress bar and the form, since the
two sit beside each other in the markup;
`docs/code-notes/app/javascript/controllers/answer_form_controller.md` covers
why the form is a target, why the submit button starts disabled, and why the
input, change and rating listeners are delegated actions. The IIFE the inline
script needed is gone with it.

## staleReloaded

This sentence is carried across the reload that a refused save triggers. It
has to describe a page that has already come back, so it is used instead of
the server's message, which asks for the refresh this script performs on its
own.

## Answer completion

The page never judges an answer. It starts from the answered sections and
submit blocker the server rendered on the form, and replaces both with each
autosave reply (`applyServerState`). Holding no copy of the rules is the point:
the browser and the server can't disagree about what counts, and the rules
aren't published to the page. The cost is that progress, the hint lock, the
status lines and the nudge follow the latest save, not each keystroke.

The status lines come as text, `section_statuses`, rendered by
`SectionStatusHelper#section_status`, so the page holds no copy of the status
rule either; it only puts each string where it belongs.

A reply is applied only when no newer save is waiting (`saveTimer === null`,
and no save queued behind it), so a reply to an older draft can't flip the page
back while the engineer is still typing. That includes a rating's checkmark:
clicking a rating marks the button at once, but the status line changes only
when the reply that stored the rating arrives, so a failed save never shows a
rating the server doesn't have.

## autoSave and sendSave

Saves go through `CodeGymSaveStatus` so a refused or dropped save is reported
rather than lost, since these are the engineer's answers.

Typing waits 800 ms after the last keystroke (`autoSave`). A rating click, and
a `change` from an answer control (leaving a text box, a design comparison
pick, a Parsons move), save at once (`sendSave`), so the nudge catches up
within one round trip at the moments someone is likely to press Submit next.
The `change` listener only acts on answer controls: the duck's box sits inside
this form, and its `change` would otherwise save a draft.

Saves go through `CodeGymSaveStatus.queue("answers", …, { latest: true })`, so
only one is on the wire at a time. Each save carries every answer, and the
server writes whichever request takes the response lock last, so two
overlapping saves could land out of order and put older answers over newer
ones. Saves asked for while one is in flight collapse into one, sent when the
first reply arrives with the answers as they are then (the body is a function
for that reason, and it returns `null` once the form is inert, which drops the
save). A reply is applied only when nothing is queued behind it
(`CodeGymSaveStatus.queued`). The queue counts toward `pending()` itself, so
pull-to-refresh waits for it.

A 409 with status `stale` means the server refused the answer's encoding (see
`ResponsesController#stale_answer_sections`) and stored nothing, so the page
has to come back before another save can land. Reloading is the whole
recovery: the server re-renders the section in the encoding it now expects.
The navigation would wipe the banner this save just set, so the explanation is
carried to the page that loads. It is `staleReloaded` rather than the
server's sentence, because the server's asks for a refresh that has already
happened by the time anyone reads it.

## Submit and review

Submit goes through `CodeGymRequest.send`. On success it chains
straight into the review, which the user asks for every time anyway. The
review is a real form POST to the URL the server returned, so `#review`'s
redirects and flashes land exactly as they do from the manual button in
`responses/_submission`; a fetch would follow the redirect itself and swallow
the flash. The two stay separate requests in the same order as two clicks:
the submission is saved and confirmed before the review is requested.

## Refused submission

Submit is never disabled. When the day isn't ready, `#create` answers with a
422 carrying `submit_blocker`; the page shows that blocker's sentence in the
nudge and moves focus to it once the form is editable again, so a screen
reader hears why nothing happened. Any other failure shows in the save banner
under its own `submit` key, with the server's sentence when it wrote one, and
the form becomes editable again. The next successful save of the answers, or a
refusal the nudge explains, clears it, so a failure that has since been
overtaken does not sit beside the nudge. There is no `alert()`: a blocking dialog
stops the page and is announced less reliably than the banner's live region.
If the submission was stored but the review could not start, the page carries
`review_start_failed` to the reload, where the submitted state offers the
review button.

A 409 on submit is the same refusal the autosave handles, on the path that
matters more: nothing was submitted, so reloading is what lets the next press
reach the server. The form stays inert behind the reload, because restoring
it would queue an autosave of the payload just refused. This path sets no
banner of its own, so the carried sentence is the only thing that tells the
reader why the page changed.

## pageshow reload

This is the second half of the guard that `DashboardController`'s `no-store`
header starts. The header stops the browser replaying this response on Back,
but Safari keeps a `no-store` page in its back-forward cache anyway and would
restore this form, still editable, for a day that is submitted and reviewed by
then. The app meets this on every iOS home-screen launch. The page reloads
rather than resetting the button the way the review and loading-form scripts
do: there only the button went stale, while here the whole form has. Answers
are autosaved, so the reload loses nothing.
