# app/controllers/sessions_controller.rb

## `#verify_code`

A rejected code gets one of two messages. With no pending login in this browser the page renders no code field, so telling the user to retry would point at a field that isn't there; they are told to request a new code instead.

## `#rate_limited`

A bare 429 would strand the user on an error page. Rendering `:new` with the alert keeps them on the page that can request a new code.

## `#pending_login_email`

This is the single authority for whether a login is pending in this browser. A state stamped with `pending_login_at` expires with its code, after `User::LOGIN_CODE_EXPIRY`.
