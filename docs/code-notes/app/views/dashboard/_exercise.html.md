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
saves and repeated submits under the response lock. The script sends both
through fetch.

## Script wrapper

The script is wrapped in an immediately invoked function so that running it a
second time cannot redeclare top-level `const` and `let` bindings. The
original comment gave Turbo re-executing the script on a replaced partial as
the reason; this app loads no Turbo JS, so that case no longer arises.

## STALE_RELOADED

This sentence is carried across the reload that a refused save triggers. It
has to describe a page that has already come back, so it is used instead of
the server's message, which asks for the refresh this script performs on its
own.

## Answer completion

Non-prose controls supply their own completion state through
`data-answer-complete`. Prose shares the server's threshold
(`DailyResponse::ANSWER_MIN_LENGTH`) and scaffold labels instead of restating
either.

## autoSave

Saves go through `CodeGymSaveStatus` so a refused or dropped save is reported
rather than lost, since these are the engineer's answers.

A 409 with status `stale` means the server refused the answer's encoding (see
`ResponsesController#stale_answer_sections`) and stored nothing, so the page
has to come back before another save can land. Reloading is the whole
recovery: the server re-renders the section in the encoding it now expects.
The navigation would wipe the banner this save just set, so the explanation is
carried to the page that loads. It is `STALE_RELOADED` rather than the
server's sentence, because the server's asks for a refresh that has already
happened by the time anyone reads it.

## Submit and review

Submit goes through fetch with the page's CSRF meta tag. On success it chains
straight into the review, which the user asks for every time anyway. The
review is a real form POST to the URL the server returned, so `#review`'s
redirects and flashes land exactly as they do from the manual button in
`responses/_submission`; a fetch would follow the redirect itself and swallow
the flash. The two stay separate requests in the same order as two clicks:
the submission is saved and confirmed before the review is requested.

## Refused submission

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
