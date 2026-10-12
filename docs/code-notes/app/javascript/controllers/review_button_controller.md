# app/javascript/controllers/review_button_controller.js

## What it owns

The "get the review" form on the submitted dashboard: relabelling its button
while the request runs, and restoring it when a Back navigation brings the
page back from bfcache.

## The deferred disable

Disabling a submit button synchronously inside a `submit` handler cancels the
submission in some browsers, so the disable is pushed into a `setTimeout(…, 0)`
that runs after the navigation has started.

## No button-versus-input branch

The inline version read and wrote the label through `textContent` or `value`
depending on the tag. `button_to` renders a `<button>`, always, so the
controller uses `textContent` only.

## No wiring guard

The inline version carried a `data-review-wired` attribute, because the script
could run again on a page that already had its listeners. Stimulus connects
each element once and disconnects it on removal, so the guard has nothing left
to prevent.
