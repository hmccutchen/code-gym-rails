# app/models/concerns/sign_in_credentials.rb

The reasoning is in `docs/decisions/password-and-authenticator-sign-in.md`.

## `DeviseOverrides`

`devise` includes its modules into `User` after this concern, so a method
defined in the concern itself would sit below Devise's in the lookup and
never run. The two overrides are prepended instead, and `super` still
reaches Devise.

## `#otp_required_for_login`

`devise-two-factor` skips the code for an account whose
`otp_required_for_login` is false, which would let an account that has not
enrolled sign in on its password alone. The reader always returns true, so
every form sign-in needs a code. The column only records whether the
authenticator is on, and `#two_factor_enrolled?` reads it directly.

## `#confirmation_required?`

Only an account created through sign-up must confirm its address: the
registration controller marks the record (`signing_up`), and a stored
confirmation token keeps it required on later loads until it confirms. Other
creation paths, the preview seed and test setup, get no confirmation email
and can sign in. Existing accounts were marked confirmed by the migration.

## `password_required`

Devise's `:validatable` is left out because it requires a password on every
new record, which the preview seed and the accounts from before passwords do
not have. The controllers that take a password set `password_required`
instead, and the length and confirmation checks apply whenever a password is
given.

## `#enroll_two_factor!` and `#regenerate_backup_codes!`

The confirming code is consumed (`validate_and_consume_otp!` stores its
timestep), so the code used to turn the authenticator on cannot also sign in.
The backup codes it returns exist only in that reply; the row keeps digests.
Both run under the row lock and re-check enrollment there, so two submits
cannot each write a set. `#prepare_two_factor_secret!` takes the lock too, so
two setup pages opened at once show the same QR code.

## `#sign_in_credentials_cleared`

`User#anonymize!` writes these values, so a deleted account keeps no
password, secret, backup code or pending token.
