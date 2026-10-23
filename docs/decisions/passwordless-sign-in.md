# Passwordless sign-in

Sign-in is an emailed 6-digit code, and that code is the only first factor. There is no password column, and there won't be one. An authenticator app will be an optional second factor, added in its own PR.

## What happened

#490 moved sign-in to Devise: a password plus a mandatory authenticator code, open sign-up with email confirmation, and emailed password resets. #491 reverted it the next day.

The owner decided to keep sign-in passwordless:
- a password adds a secret to leak and a reset flow to secure;
- the emailed code already proves the inbox, which a password reset would rely on anyway.

The second factor worth having is possession of a phone. That comes as an optional authenticator, not as a password.

## How it works now

- **Requesting a code.** `POST /login` with an email address creates the account when the address is new. Then it mails a code and records the pending sign-in in this browser's session (`LoginCodeRequests#mail_login_code`). This is open sign-up as it worked before #490: the account exists from the request, and the code proves the address.
- **The code.**
  - It comes from `SecureRandom`, and only its BCrypt digest is stored.
  - It lives 10 minutes (`User::LOGIN_CODE_EXPIRY`) and dies after five wrong guesses.
  - It is redeemed under the user row lock, so it can be used only once.
  - It works only in the browser that asked for it, because `SessionsController#verify_code` reads the address from the session.
- **Signing in.** A valid code runs `reset_session` before `session[:user_id]` is set (`SessionsController#start_new_session_for`). That gives a new session id and a new CSRF token, and it discards everything written before sign-in. `return_to` and a pending trial are read first, so they survive.
- **Signed-out requests.** `require_login` redirects every signed-out request to `/login`. `request.js` reads that redirect as "signed out". The return address is saved only for a page navigation: a GET whose `Accept` names `text/html`. An expired dashboard poll therefore never becomes the page you land on after signing in.
- **Limits.** `docs/decisions/login-rate-limits.md` has them. Their windows are 15 minutes (`User::LOGIN_RATE_LIMIT_WINDOW`), longer than a code lives.

## Stated plainly

- **No second factor yet.** Until the optional authenticator ships, every account, the owner's included, is protected by its inbox alone. That is deliberate.
- **The admin page is single-factor too.** `/admin/judge_solves` shows answer keys, and until then it is behind the emailed code alone.
- **The authenticator columns stay unread.** `otp_secret`, `consumed_timestep`, `otp_backup_codes` and `otp_required_for_login` remain on `users` for the authenticator PR. Nothing reads them now, and `User#anonymize!` clears the first three.

## The Devise columns

#490's migration added ten columns. #491 dropped the six for passwords, resets and confirmation in the same PR that removed the code. The usual rule in `.claude/rules/deployment.md` is to ignore a column for a release before dropping it, but here it protected nothing: there was one account, and the window was one deploy.

The accepted cost: if that deploy's new release had failed its health check after the migration ran, the old Devise release would have kept serving against a table with no `encrypted_password`. Sign-in would then have been broken until a fix shipped.

## Recovery

A Rails console on the production `web` service can mint a code:
```ruby
User.find_by!(email: "<address>").generate_login_code!
```

Request a code at `/login` first, so this browser has a pending sign-in, then enter the minted code. Minting replaces the emailed code. This is the way in when mail fails.
