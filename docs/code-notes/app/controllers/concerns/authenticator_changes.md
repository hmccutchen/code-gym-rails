# app/controllers/concerns/authenticator_changes.rb

`AuthenticatorsController` and `RecoveryCodesController` both change the second factor, so what they share lives here once.

## One rate limit for both

Turning the authenticator on, turning it off and making new recovery codes count against one limit of 10 per account in `User::LOGIN_RATE_LIMIT_WINDOW`. `rate_limit` keys its count on the controller's path by default, so the shared `scope:` is what makes the two controllers count together.

## `no-store`

The setup page shows the secret, and the recovery code page shows codes that are meant to be seen once. `forbid_caching` sends `Cache-Control: no-store` on both, so neither the browser cache nor the back-forward cache keeps a copy the back button could show again. `show_recovery_codes` calls it itself, so no caller can show the codes without it.

## Notices

Every change mails the account a short notice through `UserMailer#second_factor_changed`. The notice names the change and its time and never carries the key or a code. It is sent with `deliver_later` after the model's `with_lock` transaction has committed.
