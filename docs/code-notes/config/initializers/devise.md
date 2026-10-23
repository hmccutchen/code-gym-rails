# config/initializers/devise.rb

The reasoning is in `docs/decisions/password-and-authenticator-sign-in.md`.

## `Devise.otp_allowed_drift`

A code from the step before or after the current one is accepted, which
covers a phone clock that is up to 30 seconds off.

## `config.paranoid`

Sign-in, reset and confirmation replies are the same whether or not the
address has an account, so none of them tells a visitor who is registered.

## `config.reconfirmable`

No page changes an account's email address, so there is no second address
to confirm.

## `config.navigational_formats`

`request.js` recognizes an expired session by the redirect to the login page,
so JSON requests get the same redirect pages do. `SignInFailureApp` drops the
`.json` from it.

## The Warden strategies

The backup-code strategy runs before the TOTP one. Each falls through to the
next when its code does not match, so one form field takes either.
