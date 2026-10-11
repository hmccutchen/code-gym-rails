# app/javascript/controllers/loading_form_controller.js

## What it owns

Every form whose submit triggers slow server work: it disables the submit
button, adds `btn-loading`, optionally relabels it, and optionally confirms
first.

## The deferred disable

`submit` disables the button inside `setTimeout(…, 0)` rather than
synchronously. A button disabled during its own submit handler is removed from
the form's submission, so the request never leaves — the deferral lets the
submission start and then locks the button.

## It degrades without a label

`labelValue` is optional. With none, the button keeps its text and only gains
the disabled state and the class, which is what the forms that have no "doing
it" wording want.

## restore runs on bfcache only

`pageshow` fires on every load, so `restore` returns unless `event.persisted`.
Back-navigating to a page restored from the back/forward cache brings the
disabled button back exactly as it was left, which would otherwise be a dead
form.
