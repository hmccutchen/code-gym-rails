# app/controllers/first_sign_ins_controller.rb

This is the emailed-code path for accounts from before passwords. A follow-up
PR deletes it once every account has enrolled
(`docs/decisions/password-and-authenticator-sign-in.md`).

## `#create`

A code goes only to an account in `User.awaiting_password`, and the reply
text is the same for every address. Hashing a code for a real account takes a
little longer, which the rate limits bound. It creates no accounts.

## `#verify_code`

A trial the account asked for before signing in starts here, through
`after_sign_in_path_for`; without one the account goes straight to choosing a
password. `User.authenticate_login_code` checks again under the row lock that
the account still has no password, so a password set while the code was being
checked wins.


A rejected code gets one of two messages. With no pending login in this browser the page renders no code field, so telling the user to retry would point at a field that isn't there; they are told to request a new code instead.

## `#rate_limited`

A bare 429 would strand the user on an error page. Rendering `:new` with the alert keeps them on the page that can request a new code.

## `#pending_login_email`

This is the single authority for whether a login is pending in this browser. A state stamped with `pending_login_at` expires with its code, after `User::LOGIN_CODE_EXPIRY`.
