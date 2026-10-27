# app/views/dashboard/_regenerate_row.html.erb

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

## Locked while a submit runs

Both buttons are `answer-form` `replaceButton` targets, so the controller
disables them while a submit runs or waits on another save
(`docs/code-notes/app/javascript/controllers/answer_form_controller.md`). On a
submitted day there is no answer form, and the attribute does nothing.
