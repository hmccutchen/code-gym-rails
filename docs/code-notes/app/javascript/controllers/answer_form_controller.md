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

The "One finish action" decision says the Submit button is always clickable,
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
answer, and expects it saved. Without the `defaultValue` check the example
still passes eventually but takes four minutes rather than five seconds, which
is the measure of how long the answer sits unsaved.

## Submit waits for the page's controllers

Submit is always clickable, and the payload reads each section's hidden
field. A kind whose answer only reaches that field through its own controller
— the design comparison's pick and reason — would post the previous answer if
the click landed before that controller connected. So `submit()` awaits
`CodeGymBootstrap.ready`, which resolves once every controller on the page
has connected and the early-edit recorder has been settled. The click is
deferred, never dropped.
