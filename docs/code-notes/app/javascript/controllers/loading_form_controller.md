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

## The account delete renders disabled

The delete confirmation lives in `submit()`, and this controller arrives with
the rest of the page's JavaScript. A click landing before it connected
submitted the form with no confirmation at all, and the account was
anonymized — the one irreversible action in the app. So `accounts/show`
renders that button `disabled` and `connect()` enables it. Awaiting readiness
would not do: there is no safe way to replay an unconfirmed delete.

The cost is that account deletion needs JavaScript. Every other control on
the page already does.
