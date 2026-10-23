# app/controllers/authenticators_controller.rb

## The setup key lives in the session

`pending_secret` makes the key on the first view and keeps it in `session[:pending_otp_secret]`; `create` hands it to `User#enable_second_factor!`, which writes it to the row only once a code for it verifies, and then the session copy is deleted. Kept on the row instead, one key would be shared by every session: someone who signed in with only the inbox could read it before the owner enrolled it, and keep using it afterwards. The cookie session is encrypted, and a reload in the same session shows the same key, so a slow setup survives a refresh.

## The re-stamp

Turning the authenticator on or off sets `users.sessions_valid_after` to the time the model returns as `changed_at`. `finish_change` writes that same time into this session's `signed_in_at`. Every other session has an earlier stamp and is signed out on its next request; this one stays signed in. Without the re-stamp, the browser that made the change would sign itself out too.

## The recent sign-in check

`show` and `create` need `session[:signed_in_at]` within `User::RECENT_SIGN_IN`. A stolen session older than that can't add an authenticator the owner doesn't have. The sign-in-again page's button is `DELETE /account/authenticator/sign_in_again`, which signs out and saves this page as `return_to`, so the next sign-in comes straight back here.

## `no-store`

`show` and `create` send `Cache-Control: no-store` through `AuthenticatorChanges#forbid_caching`, since both can render the secret or the recovery codes. `destroy` only redirects, so it needs none.
