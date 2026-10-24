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

The authenticator setup's Turn on and the Account page's New recovery codes
render disabled for the same reason, although neither has a confirm message.
Each response is the only time its recovery codes are shown. A second post
before the controller connected would replace that page with the Account
page, and after New recovery codes the old codes would already be gone.

The cost is that those buttons need JavaScript. The dashboard already
needs it for answering and submitting. On the Account page only deletion and New
recovery codes do: logging out, pausing and resuming generation, and the reminder settings still
submit without it. The authenticator setup page needs it to turn the authenticator on.

## Sign-in and authenticator forms

The email, emailed-code, second-step, Turn on, Turn off, new recovery codes
and trial forms all use it. Each of those posts spends something on the
server: a login code is cleared once it is redeemed, and turning the
authenticator on ends every other session. Sign-in requests take a second or
two in production, so a second tap was easy. The browser then showed the
second response, which said the spent code was wrong, or signed the user out
before they saw their recovery codes. Disabling the button after the first
submit stops the second post. A tap that lands before the controller connects
still posts twice on the sign-in forms, so the server accepts that repeat:
`SignInCompletion#recent_sign_in` signs in a second post that
carries the same pending stamp and code within `REPEAT_WINDOW`. That keeps
sign-in working without JavaScript. Every form gets its wiring from
`LoadingFormHelper#loading_form_data`, and `sign_in_form_guards_spec` checks
that each of these forms is wired to both actions, `submit` and `restore`. `code_login_spec` and
`second_factor_spec` double-tap Verify code and Turn on in a real browser.
