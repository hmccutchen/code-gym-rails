# Passwordless sign-in

Sign-in starts with an email address. Without an authenticator, an emailed 6-digit code signs the account in. An account can turn on an authenticator app from its Account page, and from then on the app replaces the emailed code: the address, then a code from the app or a recovery code. There is no password column, and there won't be one.

## What happened

#490 moved sign-in to Devise: a password plus a mandatory authenticator code, open sign-up with email confirmation, and emailed password resets. #491 reverted it the next day.

The owner decided to keep sign-in passwordless:
- a password adds a secret to leak and a reset flow to secure;
- the emailed code already proves the inbox, which a password reset would rely on anyway.

The extra factor worth having is possession of a phone. That came as an optional authenticator in the PR after #491 (#493), not as a password. The section below holds its decisions.

#493 asked for the emailed code and then the authenticator code. The owner found that redundant, and decided that once the authenticator is on it replaces the emailed code. The trade-offs are under "Stated plainly".

## How it works now

- **Requesting a code.** `POST /login` with an email address creates the account when the address is new. Then it queues the email and records the pending sign-in in this browser's session (`LoginCodeRequests#mail_login_code`). The mailer mints the code while it builds the email, so the job carries only the account: a code passed in as an argument would sit in plain text in `solid_queue_jobs` and in the enqueue log line. This is open sign-up as it worked before #490: the account exists from the request, and the code proves the address. An account with the authenticator on gets no email: `SessionsController#create` sends it straight to the second step.
- **The code page.** After the request, the code field is on `GET /login/code`, and `GET /login` redirects there while the sign-in is pending. Start again (`DELETE /login/code`) forgets the pending sign-in and shows the email form.
- **The code.**
  - It comes from `SecureRandom`, and only its BCrypt digest is stored.
  - It lives 10 minutes (`User::LOGIN_CODE_EXPIRY`) and dies after five wrong guesses.
  - It is redeemed under the user row lock, so it can be used only once.
  - It works only in the browser that asked for it, because `SessionsController#verify_code` reads the address from the session.
- **Signing in.** A valid code, and the authenticator code when that is on, runs `reset_session` before `session[:user_id]` is set (`SignInCompletion#start_new_session_for`). That gives a new session id and a new CSRF token, and it discards everything written before sign-in. `return_to` and a pending trial are read first, so they survive. A second post of the same code from the same browser within 30 seconds, as a double tap sends, signs in too, rather than saying the spent code was wrong (`SignInCompletion#recent_sign_in`). The repeat keeps the first post's check time, so a session ended since then stays ended. `SignInCompletion#complete_sign_in` names the factor that passed and raises `WrongFactor` for the emailed code on an authenticator account, so no sign-in path can finish one on the inbox alone.
- **The sign-in stamp.** Sign-in also writes `session[:signed_in_at]`. A session counts only while that stamp is at or after `users.sessions_valid_after` (`SignedInSessions`). Pages and the cable connection both check it through `User.signed_in_through`.
- **Signed-out requests.** `require_login` redirects every signed-out request to `/login`. `request.js` reads that redirect as "signed out". The return address is saved only for a page navigation: a GET whose `Accept` names `text/html`. An expired dashboard poll therefore never becomes the page you land on after signing in. Reloading the page a rejected code renders, a `POST /login/code`, sends a `GET` there, which shows the code page again.
- **Limits.** `docs/decisions/login-rate-limits.md` has them. Their windows are 15 minutes (`User::LOGIN_RATE_LIMIT_WINDOW`), longer than a code lives.

## The authenticator app

### Decisions

1. **Start clean.** The migration cleared `otp_secret`, `consumed_timestep` and `otp_backup_codes` for every account. They might have held a secret from the #490 enrollment, which the authenticator app may no longer show.
2. **`two_factor_enabled_at` replaced `otp_required_for_login`.** It's a nullable datetime: set when the authenticator is turned on, nil when it's off. The Account page shows it as "On since".
3. **Turning it on needs a recent sign-in:** `session[:signed_in_at]` within the last 15 minutes (`User::RECENT_SIGN_IN`), plus a valid code from the new authenticator. A stolen session therefore can't turn on an authenticator the owner doesn't have, which would lock the owner out. An older session is asked to sign in again first.
   - **The setup key belongs to one session.** The setup page makes a key and keeps it in that browser's encrypted session (`AuthenticatorsController#pending_secret`). The key reaches `users.otp_secret` only when a code for it turns the authenticator on (`User#enable_second_factor!`), so viewing the page writes nothing. Two sessions see two different keys. Without this, an inbox-only session could read the key, the owner could later enroll that same key, and the intruder would then sign in with the address and a code from that key, which is all an authenticator account asks for. A reload in the same session keeps its key; signing in again shows a new one.
4. **Turning it off, and making new recovery codes, need an authenticator code or a recovery code.** The emailed code is refused, since the inbox is the factor the authenticator replaces.
5. **Every change mails the account a notice:** turning it on, turning it off, and making new recovery codes. The notice says what changed and when, never the key or a code.
6. **Ten recovery codes,** shown once. Each is 10 characters from a 32-letter alphabet with no `0`, `O`, `1` or `I`, written as two groups of five, for 50 bits. Each is stored as a bcrypt digest and works once.
7. **No "remember this device".** Every sign-in asks for the authenticator once it's on.
8. **A daily cap of 20 wrong codes per account in 24 hours.** Only failures count. It covers the sign-in step, turning the authenticator off, and making new codes. Once it's reached, those three refuse every code, recovery codes included, until 24 hours after the first failure in the window.
9. **Every count of wrong codes lives on the user row,** never in the session cookie. A copied cookie replayed later therefore can't bring back a zero count. The row, rather than the cache, keeps the counts through a cache eviction or a deploy.
10. **Secrets stay out of caches and logs.** The setup page and every page showing recovery codes send `Cache-Control: no-store`. Every code field is named `otp_code`, which the existing `:otp` filter hides, and nothing writes the setup key or the `otpauth://` link to the log. `spec/requests/second_factor_logging_spec.rb` pins this.
11. **Turning the authenticator on or off ends every other session.** Sessions live in the cookie, so the server keeps no list to cancel. Instead the change sets `sessions_valid_after`, and the session that made the change gets a new stamp in the same request. Making new recovery codes doesn't end sessions, because it doesn't change who can sign in from now on.

### Why 20 a day

With one step of clock drift either way, three TOTP codes are valid at any moment, out of 1,000,000. Each guess hits with probability 3 in a million.

- The 15-minute limits alone allow 10 guesses per 15 minutes. Kept up for a year, that's 350,400 guesses, and 1 − (1 − 3×10⁻⁶)^350,400 ≈ 65%.
- Twenty a day for a year is 7,300 guesses, ≈ 2%.

### The sign-in step

When the address belongs to an account with the authenticator on, `SessionsController#create` mails nothing. It issues a challenge on the user row and stores `session[:pending_second_factor]`, then sends the browser to `/login/second-factor`. `#verify_code` does the same if an emailed code arrives for such an account, for example from the trial form, so an emailed code never signs it in alone.

- The challenge lasts 5 minutes and ends after 5 wrong codes, counted on the row.
- A right code, the daily cap, or expiry also ends it. Each sends the user back to `/login` to enter the address again, except a right code, which signs in.
- The pending marker sets no `user_id`, so every page and the cable connection treat the browser as signed out until the second step passes.

## Stated plainly

- **Without the authenticator, an account is protected by its inbox alone.** That includes the admin page, `/admin/judge_solves`, which shows answer keys. Turning the authenticator on is the owner's choice.
- **Anyone who knows the address can lock the owner out for a day.** Once the authenticator is on, the address alone reaches the second step, and 20 wrong codes there use up the daily cap. They still can't sign in. The owner waits out the window or clears the cap from the console. The owner accepted this for a small team app.
- **The login page tells whether an address has the authenticator on.** It goes to the second step instead of the code page.
- **A new request ends the open challenge.** Each `POST /login` for the address issues a fresh challenge, so someone sending the address while the owner is on the second step sends the owner back to the start. The per-address request limit bounds how often.
- **With the authenticator on, the inbox alone can't sign in.** Neither the emailed code nor anything else in the inbox opens the account.
- **With the authenticator on, one 6-digit code is the whole credential.** Anyone who knows the address can open challenges, and the daily cap is the only limit that binds: the per-challenge, per-account and per-address limits allow far more. At 20 guesses a day, a persistent attacker has about a 2% chance in a year of guessing a code (see "Why 20 a day"). Before this change the same guesses also needed the inbox.
- **Deploying the sign-in stamp signed everyone out once.** No session from before it had `signed_in_at`, so each counted as signed out.
- **Someone holding the inbox can turn the authenticator on with their own phone.** A fresh sign-in through the emailed code is all decision 3 asks for, and the recovery codes go to them. The owner then can't sign in until the console reset under "Lost phone and codes" below, and the change notice goes to the same inbox. The authenticator guards against a stolen session or a guessed code, not against someone who already reads the inbox before it is turned on.
- **Recovery codes are the only way past a lost phone** short of the console.
- **Rolling back to code from before the authenticator turns it off silently.** That code never reads `two_factor_enabled_at`, so an enrolled account signs in with the emailed code alone, and `sessions_valid_after` stops ending sessions. The columns survive, so redeploying this code turns enrollments back on. Tell the account owners before such a rollback.

## Recovery

A Rails console on the production `web` service is the way in when everything else fails.

**Mail doesn't arrive.** Mint a code:
```ruby
User.find_by!(email: "<address>").generate_login_code!
```
Request a code at `/login` first, so this browser has a pending sign-in, then enter the minted code. Minting replaces the emailed code.

**Lost phone, codes kept.** Enter the address, then a recovery code. Turn the authenticator off and add it again on the new phone.

**Lost phone and codes.** Turn the authenticator off from the console, then sign in with the emailed code:
```ruby
User.find_by!(email: "<address>").update!(two_factor_enabled_at: nil, otp_secret: nil, consumed_timestep: nil, otp_backup_codes: nil, second_factor_failures: 0, second_factor_failures_since: nil, second_factor_challenge_at: nil, second_factor_challenge_failures: 0)
```

**Locked by the daily cap, phone in hand.** Wait out the window, or clear the cap:
```ruby
User.find_by!(email: "<address>").update!(second_factor_failures: 0, second_factor_failures_since: nil)
```

The emailed code never signs in an account with the authenticator on, and never removes it. Only an authenticator code, a recovery code, or the console can.

## The Devise columns

#490's migration added ten columns. #491 dropped the six for passwords, resets and confirmation in the same PR that removed the code. The usual rule in `.claude/rules/deployment.md` is to ignore a column for a release before dropping it, but here it protected nothing: there was one account, and the window was one deploy. The authenticator PR dropped `otp_required_for_login` the same way and reused the other three.

The accepted cost: if that deploy's new release had failed its health check after the migration ran, the old Devise release would have kept serving against a table with no `encrypted_password`. Sign-in would then have been broken until a fix shipped.

## Checks still to run on production

The local-network phone check covers the second step and the setup page. Two things need HTTPS and the installed home-screen app, so they wait for production:
- whether the `otpauth://` link opens the authenticator from the installed iOS app;
- whether Copy and Copy all work from Safari and from the installed app, or fall back to selecting the text.

Record the results here. If the link doesn't open the app from the installed app, the setup key is the way there.
