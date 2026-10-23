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

## Confirmed forms render disabled

The confirmation lives in `submit()`, and this controller arrives with the
rest of the page's JavaScript. A click landing before it connected submitted
the form with no confirmation at all. On the account delete that anonymized
the account, the one irreversible action in the app; on the dashboard's
Generate new set and Start over it destroyed the day's draft answers. So every
form with a confirm message renders its button `disabled`, and `connect()`
enables it. Awaiting readiness would not do: there is no safe way to replay an
unconfirmed submit.

The cost is that those three buttons need JavaScript. The dashboard already
needs it for answering and submitting. On the Account page only deletion does:
logging out, pausing and resuming generation, and the reminder settings still
submit without it.

## Sign-in and authenticator forms

The email, emailed-code, second-step, Turn on, Turn off, new recovery codes
and trial forms all use it. Each of those posts spends something on the
server: a login code is cleared once it is redeemed, and turning the
authenticator on ends every other session. Sign-in requests take a second or
two in production, so a second tap was easy. The browser then showed the
second response, which said the spent code was wrong, or signed the user out
before they saw their recovery codes. Disabling the button after the first
submit stops the second post. `sign_in_form_guards_spec` checks that each of
these forms is wired to the controller. `code_login_spec` and
`second_factor_spec` double-tap Verify code and Turn on in a real browser.
