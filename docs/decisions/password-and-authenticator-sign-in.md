# Password and authenticator sign-in

Sign-in used to be an emailed 6-digit code, built by hand: a BCrypt digest on
the user row, a pending-login state in the session, and a set of rate limits
around guessing. It worked, but every part of it was our own code to keep
correct. After the Railway breach (PR #482) the owner chose to move to Devise
with time-based one-time passwords (TOTP) from an authenticator app, so the
parts that matter for security come from maintained libraries.

## What was chosen

The owner made each of these calls:

- **A password plus an authenticator code**, using Devise with
  `devise-two-factor`. The gem is built as a second factor on top of a
  password, so this uses it as designed. An emailed code plus TOTP would
  have kept the hand-built half, and TOTP with no password has no supported
  Devise strategy.
- **Backup codes** for a lost phone (`:two_factor_backupable`), ten
  single-use codes shown once when the authenticator is turned on
  (`SignInCredentials::BACKUP_CODE_COUNT`). An admin can reset anyone who
  loses those too. A Devise emailed reset was turned down for the
  authenticator, because whoever holds the inbox could then take the account.
- **Open sign-up with email confirmation** (`:confirmable`). Anyone can
  register, and the account works only after the emailed link is followed.
  That keeps the old guarantee that the address belongs to the person.
- **An emailed password reset link** (`:recoverable`). The reset never signs
  in (`sign_in_after_reset_password = false`), so the authenticator code is
  still needed after it, and an inbox alone is not enough to get in.
- **Existing accounts enroll at their next sign-in.** Each of them has no
  password, so the login page offers them one last emailed code
  (`FirstSignInsController`, `/login/first`). Right after it they must set a
  password (`PasswordSetupsController`) and turn on the authenticator
  (`TwoFactorSetupsController`). A follow-up PR deletes that path once every
  account has enrolled.

## How a request is gated

`ApplicationController` runs three checks after Devise's `authenticate_user!`,
in order, for a signed-in user outside Devise's own controllers:

1. `require_password` sends an account with no password to choose one.
2. `require_two_factor` sends an account without an authenticator to set one up.
3. `require_provider`, unchanged, sends an account with no key to Setup.

The setup controllers skip only the checks that come after their own step.
An account that registered but has not set up its authenticator can still
sign in with its password alone, since `otp_required_for_login` is false, and
the second check then sends it to the setup page. So the authenticator is
required for every page except its own setup.

## The login form takes all three values at once

The form asks for the email, the password and the authenticator or backup
code together, and posts them to Devise's own `sessions#create`. The gem's
strategies (`two_factor_backupable`, then `two_factor_authenticatable`) check
them in one request. A two-page flow (password first, then code) would have
meant holding a half-signed-in user in the session ourselves, which is the
hand-built state this change set out to remove. Every failure gets one
message, "Incorrect email, password or code", so the reply does not say which
part was wrong. A code is consumed when used (`consumed_timestep`), so the
same code cannot sign in twice.

## Who has to confirm an address

Devise's confirmable asks every new row to confirm. Here only an account
created through sign-up does: `SignInCredentials::DeviseOverrides#confirmation_required?`
is true when the registration controller marks the record (`signing_up`) or
when a confirmation token is already stored. Other creation paths are the
preview seed, which is trusted, and test setup. Existing accounts proved their
address with emailed codes, so the migration marks them confirmed.

## Two traps in Devise's callback order

Devise's sessions controller prepends `allow_params_authentication!`, so it
runs before anything this app declares. After it, any call to `current_user`
in that request runs the strategies against the posted params and can sign
the user in. Two places hit this:

- **A rate-limited sign-in.** Rendering the refusal page made the layout call
  `current_user` and signed in the user whose password and code were posted.
  The limits in `Users::SessionsController` are declared with `prepend: true`
  so they refuse before params authentication is allowed.
- **A stale CSRF token.** The handler that sends a double-tapped form home
  checked `user_signed_in?`, which signed in a request whose token had failed.
  It now reads `warden.authenticated?(:user)`, which looks only at the stored
  session. Devise answers a double-tapped login form itself, before the token
  check, with "You are already signed in", so the handler's special case now
  covers only the emailed-code form.

## JSON requests

`request.js` recognizes an expired session by the redirect to the login page.
Devise answers an unauthenticated JSON request with a 401 by default, so
`config.navigational_formats` includes `:json`, and `SignInFailureApp` sends
it to `/login` rather than `/login.json`.

## Limits

`Users::SessionsController` allows 10 sign-in attempts per address and 20
per IP in 15 minutes. `Users::RegistrationsController` allows 10 sign-ups per
IP an hour. `TwoFactorSetupsController` allows 10 enrollment attempts per
account in 15 minutes. The emailed-code path keeps its old limits, apart from
the daily per-IP cap on code requests, which existed to bound account
creation: that path no longer creates accounts.

## What did not change

- Sessions stay in the cookie store with the same key and two-day expiry.
  Everyone is still signed out once by the deploy, because an existing
  session holds the old `user_id` key, which Devise does not read.
- `PendingTrial` still starts a trial at sign-in, now from
  `ApplicationController#after_sign_in_path_for`. Trial start sends the
  visitor to sign up instead of mailing a code.
- `PreviewAutoLogin` signs the seeded reviewer in through Devise's `sign_in`.
  The seed gives that account a random password and an authenticator, so
  auto-login lands past the setup checks.
