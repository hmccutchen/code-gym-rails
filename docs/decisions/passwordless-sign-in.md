# Passwordless sign-in

Sign-in is an emailed 6-digit code, and that code is the only first factor. There is no password column, and there won't be one. An authenticator app is an optional second factor, which each account can turn on from its Account page.

## What happened

#490 moved sign-in to Devise: a password plus a mandatory authenticator code, open sign-up with email confirmation, and emailed password resets. #491 reverted it the next day.

The owner decided to keep sign-in passwordless:
- a password adds a secret to leak and a reset flow to secure;
- the emailed code already proves the inbox, which a password reset would rely on anyway.

The second factor worth having is possession of a phone. That came as an optional authenticator in the PR after #491, not as a password. Its spec is `docs/optional-totp-spec-2026-10-23.md`.

## How it works now

- **Requesting a code.** `POST /login` with an email address creates the account when the address is new. Then it mails a code and records the pending sign-in in this browser's session (`LoginCodeRequests#mail_login_code`). This is open sign-up as it worked before #490: the account exists from the request, and the code proves the address.
- **The code.**
  - It comes from `SecureRandom`, and only its BCrypt digest is stored.
  - It lives 10 minutes (`User::LOGIN_CODE_EXPIRY`) and dies after five wrong guesses.
  - It is redeemed under the user row lock, so it can be used only once.
  - It works only in the browser that asked for it, because `SessionsController#verify_code` reads the address from the session.
- **Signing in.** A valid code, and the authenticator code when that is on, runs `reset_session` before `session[:user_id]` is set (`SignInCompletion#start_new_session_for`). That gives a new session id and a new CSRF token, and it discards everything written before sign-in. `return_to` and a pending trial are read first, so they survive.
- **The sign-in stamp.** Sign-in also writes `session[:signed_in_at]`. A session counts only while that stamp is at or after `users.sessions_valid_after` (`SignedInSessions`). Pages and the cable connection both check it through `User.signed_in_through`.
- **Signed-out requests.** `require_login` redirects every signed-out request to `/login`. `request.js` reads that redirect as "signed out". The return address is saved only for a page navigation: a GET whose `Accept` names `text/html`. An expired dashboard poll therefore never becomes the page you land on after signing in.
- **Limits.** `docs/decisions/login-rate-limits.md` has them. Their windows are 15 minutes (`User::LOGIN_RATE_LIMIT_WINDOW`), longer than a code lives.

## The authenticator app

### Decisions

1. **Start clean.** The migration cleared `otp_secret`, `consumed_timestep` and `otp_backup_codes` for every account. They might have held a secret from the #490 enrollment, which the authenticator app may no longer show.
2. **`two_factor_enabled_at` replaced `otp_required_for_login`.** It's a nullable datetime: set when the authenticator is turned on, nil when it's off. The Account page shows it as "On since".
3. **Turning it on needs a recent sign-in:** `session[:signed_in_at]` within the last 15 minutes (`User::RECENT_SIGN_IN`), plus a valid code from the new authenticator. A stolen session therefore can't turn on an authenticator the owner doesn't have, which would lock the owner out. An older session is asked to sign in again first.
4. **Turning it off, and making new recovery codes, need an authenticator code or a recovery code.** The emailed code is refused, since the inbox is the factor this one backs up.
5. **Every change mails the account a notice:** turning it on, turning it off, and making new recovery codes. The notice says what changed and when, never the key or a code.
6. **Ten recovery codes,** shown once. Each is 10 characters from a 32-letter alphabet with no `0`, `O`, `1` or `I`, written as two groups of five, for 50 bits. Each is stored as a bcrypt digest and works once.
7. **No "remember this device".** Every sign-in asks for the second factor once it's on.
8. **A daily cap of 20 wrong codes per account in 24 hours.** Only failures count. It covers the sign-in step, turning the authenticator off, and making new codes. Once it's reached, those three refuse every code, recovery codes included, until 24 hours after the first failure in the window.
9. **Every count of wrong codes lives on the user row,** never in the session cookie. A copied cookie replayed later therefore can't bring back a zero count. The row, rather than the cache, keeps the counts through a cache eviction or a deploy.
10. **Secrets stay out of caches and logs.** The setup page and every page showing recovery codes send `Cache-Control: no-store`. Every code field is named `otp_code`, which the existing `:otp` filter hides, and nothing writes the setup key or the `otpauth://` link to the log. `spec/requests/second_factor_logging_spec.rb` pins this.
11. **Turning the authenticator on or off ends every other session.** Sessions live in the cookie, so the server keeps no list to cancel. Instead the change sets `sessions_valid_after`, and the session that made the change gets a new stamp in the same request. Making new recovery codes doesn't end sessions, because it doesn't change who can sign in from now on.

### Why 20 a day

With one step of clock drift either way, three TOTP codes are valid at any moment, out of 1,000,000. Each guess hits with probability 3 in a million.

- The 15-minute limits alone allow 10 guesses per 15 minutes. Kept up for a year, that's 350,400 guesses, and 1 − (1 − 3×10⁻⁶)^350,400 ≈ 65%.
- Twenty a day for a year is 7,300 guesses, ≈ 2%.

### The sign-in step

When the emailed code is right and the authenticator is on, `SessionsController#verify_code` doesn't sign in. It issues a challenge on the user row and stores `session[:pending_second_factor]`, then sends the browser to `/login/second-factor`.

- The challenge lasts 5 minutes and ends after 5 wrong codes, counted on the row.
- A right code, the daily cap, or expiry also ends it. Each sends the user back to `/login` for a new emailed code, except a right code, which signs in.
- The pending marker sets no `user_id`, so every page and the cable connection treat the browser as signed out until the second step passes.

## Stated plainly

- **Without the authenticator, an account is protected by its inbox alone.** That includes the admin page, `/admin/judge_solves`, which shows answer keys. Turning the authenticator on is the owner's choice.
- **Someone holding the inbox can lock the owner out for a day.** With the emailed code they reach the second step, and 20 wrong codes there use up the daily cap. They still can't sign in. The owner waits out the window or clears the cap from the console.
- **Deploying the sign-in stamp signed everyone out once.** No session from before it had `signed_in_at`, so each counted as signed out.
- **Recovery codes are the only way past a lost phone** short of the console.

## Recovery

A Rails console on the production `web` service is the way in when everything else fails.

**Mail doesn't arrive.** Mint a code:
```ruby
User.find_by!(email: "<address>").generate_login_code!
```
Request a code at `/login` first, so this browser has a pending sign-in, then enter the minted code. Minting replaces the emailed code.

**Lost phone, codes kept.** Sign in with the emailed code and then a recovery code. Turn the authenticator off and add it again on the new phone.

**Lost phone and codes.** Turn the authenticator off from the console, then sign in with the emailed code:
```ruby
User.find_by!(email: "<address>").update!(two_factor_enabled_at: nil, otp_secret: nil, consumed_timestep: nil, otp_backup_codes: nil, second_factor_failures: 0, second_factor_failures_since: nil, second_factor_challenge_at: nil, second_factor_challenge_failures: 0)
```

**Locked by the daily cap, phone in hand.** Wait out the window, or clear the cap:
```ruby
User.find_by!(email: "<address>").update!(second_factor_failures: 0, second_factor_failures_since: nil)
```

The emailed code never removes the second factor. Only an authenticator code, a recovery code, or the console can.

## The Devise columns

#490's migration added ten columns. #491 dropped the six for passwords, resets and confirmation in the same PR that removed the code. The usual rule in `.claude/rules/deployment.md` is to ignore a column for a release before dropping it, but here it protected nothing: there was one account, and the window was one deploy. The authenticator PR dropped `otp_required_for_login` the same way and reused the other three.

The accepted cost: if that deploy's new release had failed its health check after the migration ran, the old Devise release would have kept serving against a table with no `encrypted_password`. Sign-in would then have been broken until a fix shipped.

## Checks still to run on production

The local-network phone check covers the second step and the setup page. Two things need HTTPS and the installed home-screen app, so they wait for production:
- whether the `otpauth://` link opens the authenticator from the installed iOS app;
- whether Copy and Copy all work from Safari and from the installed app, or fall back to selecting the text.

Record the results here. If the link doesn't open the app from the installed app, the setup key is the way there.
