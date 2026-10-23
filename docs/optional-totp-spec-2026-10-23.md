# PR 2 spec: an optional authenticator app as a second factor

Written 2026-10-23. It builds on #491, which restored passwordless sign-in and kept the authenticator columns. Line numbers and behavior below are as of #491's head, `bf03e2f1`.

This PR starts after #491 has merged and passed its post-deploy check.

## What this adds, and what it buys

Today the emailed code is the only factor, so an account is only as safe as its inbox. This PR adds an optional second factor: a 6-digit time-based code (TOTP) from an authenticator app.

**What it protects against:**
- A compromised or forwarded inbox. With an authenticator turned on, anyone who reads the code email still needs the phone.

**What it doesn't protect against:**
- **Real-time phishing**, where a fake page relays both codes as they're typed.
- **One device holding everything.** On a phone-first PWA, the same phone often holds the email, the authenticator and the open session. Losing that phone unlocked loses all three.

**Opt-in, for every account.** Nothing requires it, and that includes admin accounts. Requiring it for admins is a follow-up to consider once this has been used.

## Context

- I'm the only account, and every risk judgement below assumes that.
- There is no support desk. A lost phone without recovery codes means a console fix (see "Recovery").

## Decisions

These are the recommended defaults. Change any of them before the plan is written.

1. **Start clean.** A migration clears `otp_secret`, `consumed_timestep` and `otp_backup_codes` for every account.
   - These may hold a secret from my #490 enrollment, which the authenticator app may no longer show. Honoring it would demand a code I might not have.
   - The columns themselves are reused.
2. **Replace `otp_required_for_login` with `two_factor_enabled_at`.**
   - The new column is a nullable datetime: it's set when the authenticator is turned on and nil when it's off.
   - This is a new column plus a removal, with no alias. The old name was devise-two-factor's and described Devise's behavior.
   - A timestamp also lets the Account page say when it was turned on.
3. **Turning it on needs a recent sign-in.** "Recent" means `session[:signed_in_at]` within the last 15 minutes, plus a valid code from the new authenticator.
   - This is so that a stolen session can't turn on an authenticator the owner doesn't have. That would lock the owner out.
   - An older session is asked to sign in again first.
4. **Turning it off, and making new recovery codes, need a current authenticator code or a recovery code.** The emailed code is not enough, since the inbox is the factor this one is meant to back up.
5. **The account's email is told about every change.** Turning the authenticator on, turning it off and making new recovery codes each send a short notice: what changed, when, and what to do if it wasn't you.
6. **Ten recovery codes,** each shown once.
   - Each code is 10 characters from a 32-letter alphabet with no `0`, `O`, `1` or `I`, written as two groups of five, for 50 bits.
   - Each is stored as a bcrypt digest and works once.
7. **No "remember this device".** Every sign-in asks for the second factor once it's on (YAGNI).
8. **A daily cap on wrong codes per account: 20 failures in 24 hours.**
   - Only failures count, so normal sign-ins never use it up.
   - It covers the sign-in step, turning the authenticator off, and making new recovery codes.
   - Once it's reached, those three refuse everything for that account until the window passes, recovery codes included. The console line under "Recovery" is the way out.
   - **Why 20 a day.** With one step of drift either way, three codes are valid at any moment, out of 1,000,000. Each guess therefore hits with probability 3 in a million.
     - The 15-minute limits alone allow 10 guesses per 15 minutes. Kept up for a year, that's 350,400 guesses, and 1 − (1 − 3×10⁻⁶)^350,400 ≈ 65%.
     - Twenty a day for a year is 7,300 guesses, ≈ 2%.
9. **Every count of wrong codes lives on the user row, never in the session cookie.**
   - Otherwise someone holding a copied cookie could replay it to bring back a zero count.
   - The row, rather than the cache, keeps the counts through a cache eviction or a deploy, and lets the row lock that already guards verification count them.
10. **Secrets stay out of caches and logs.**
    - Pages showing the setup key or recovery codes send `Cache-Control: no-store`.
    - The code field is named `otp_code`, which the existing `:otp` filter already hides.
    - Nothing writes the setup key or the `otpauth://` link to the log.
11. **Turning the authenticator on or off ends every other session.**
    - **Why.** Sessions live in the cookie, so the server keeps no list of them to cancel. Say I turn on the authenticator because I think my inbox was read. Without this, the intruder's session from that inbox stays signed in.
    - **The mechanism.**
      - A new column, `sessions_valid_after`, records when this last happened.
      - A session counts as signed out when its `session[:signed_in_at]` is missing or earlier than that time.
      - The session that made the change is stamped again in the same request, so the device I'm using stays signed in.
    - **Making new recovery codes doesn't end sessions.** It doesn't change who can sign in from now on.
    - **On deploy, everyone is signed out once.** A session created before this PR has no `signed_in_at`, so it counts as signed out. That is accepted; with one account, it means signing in once more.

## Data

| Column | Change |
|---|---|
| `otp_secret` | Read and written through `encrypts :otp_secret`. devise-two-factor used Active Record encryption with default options, so existing ciphertext would decrypt. Decision 1 clears it anyway. |
| `consumed_timestep` | The last accepted TOTP time step (Unix time ÷ 30). A code is accepted only for a later step. |
| `otp_backup_codes` | bcrypt digests of the unused recovery codes; a used code's digest is removed. |
| `otp_required_for_login` | Dropped (decision 2). |
| `two_factor_enabled_at` | New; nil means off. |
| `second_factor_challenge_at` | New, nullable datetime. When the current sign-in challenge was issued; nil when there is none (decision 9). |
| `second_factor_challenge_failures` | New, integer, default 0, not null. Wrong codes against the current challenge; set to 0 when a challenge is issued. |
| `second_factor_failures` | New, integer, default 0, not null. Wrong codes in the current 24-hour window (decision 8). |
| `second_factor_failures_since` | New, nullable datetime. When the current window began, at its first failure. |
| `sessions_valid_after` | New, nullable datetime. A session signed in before this time counts as signed out (decision 11). |

**Migration:**
- Add `two_factor_enabled_at`, the four failure and challenge columns, and `sessions_valid_after`.
- Remove `otp_required_for_login` with its type, `boolean, null: false, default: false`.
- Clear the three `otp_*` columns with `update_all`.

The clearing step can't be undone, and that's by design. With one account, the column change needs no two-release split, for the reasons #491 gave.

**`User#anonymize!`** also clears `two_factor_enabled_at`, the challenge and failure columns, and `sessions_valid_after`.

## Model

Add a `SecondFactor` concern in `app/models/concerns/`, included by `User`.

- **Pure decisions** stay free of side effects where they can, as `.claude/rules/patterns.md` asks: verifying a code against a secret and a step.
- **Writes** run under the user row lock (`with_lock`), so two submits of one code can't both succeed.

**Methods:**
- `two_factor_enabled?`: `two_factor_enabled_at.present?`.
- `session_signed_in_valid?(signed_in_at)`: the one rule for whether a session still counts (decision 11).
  - It's false when `signed_in_at` is missing or can't be read.
  - It's false when `signed_in_at` is earlier than `sessions_valid_after`.
  - It's true otherwise.

  Both callers use it: `ApplicationController#current_user` and `ApplicationCable::Connection#find_verified_user`. The websocket therefore can't keep alive a session the pages reject.
- `prepare_second_factor!`: under the lock, sets `otp_secret` to `ROTP::Base32.random` (160 bits) when blank and the authenticator is off, and returns it. Two open setup pages show the same secret.
- `enable_second_factor!(code)`: under the lock, accepts a valid TOTP for the pending secret. It sets `consumed_timestep`, `two_factor_enabled_at` and `sessions_valid_after`, generates the ten recovery codes, and returns them in an outcome.
  - `two_factor_enabled_at` and `sessions_valid_after` take the same `now`, and the outcome carries it. Already on → `:already_on`; wrong code → `:rejected`.
- `verify_second_factor!(code)`: under the lock. A TOTP is accepted through `ROTP::TOTP#verify(code, drift_behind: 30, drift_ahead: 30, after: consumed_timestep * 30)`, which allows one step of clock drift either way and rejects a reused or older code. On a match it stores the step. A recovery code is accepted when it matches a stored digest, and that digest is removed. Returns `:totp`, `:recovery_code`, `:rejected` or `:locked`.
  - **The daily cap.** It first checks the cap (decision 8). If `second_factor_failures` has reached 20 and `second_factor_failures_since` is less than 24 hours old, it returns `:locked` without looking at the code.
  - **Counting a failure.** A rejected code starts a new window if the old one has expired, then adds one to `second_factor_failures`. A success changes neither column.
  - **Constants.** The limits are `User::SECOND_FACTOR_DAILY_FAILURES = 20` and `User::SECOND_FACTOR_CHALLENGE_FAILURES = 5`, each stated once.
- `regenerate_recovery_codes!(code)` and `disable_second_factor!(code)`: each runs `verify_second_factor!` first.
  - **Turning it off** clears `otp_secret`, `consumed_timestep`, `otp_backup_codes` and `two_factor_enabled_at`. Under the same lock it sets `sessions_valid_after` to `now`, and the outcome carries that time.
  - **Making new codes** leaves `sessions_valid_after` alone.

**Stamping sessions.** `session[:signed_in_at]` holds microseconds, as `iso8601(6)`, matching the column's precision.
- `start_new_session_for` writes it at every sign-in. So does `PreviewAutoLogin`, which signs in without going through `start_new_session_for`.
- After turning the authenticator on or off, the controller writes the outcome's `now` into the current session.
- The comparison is "earlier than", so a session stamped with that exact time still counts.

Each action returns a named outcome, following "Outcomes at the HTTP edge", and the controller only maps it to a page.

**Code format:** TOTP is SHA-1, 6 digits and 30 seconds, which every authenticator app supports. Input is trimmed, spaces are removed, and recovery codes compare case-insensitively.

**Gems:** add `rotp ~> 6.3` and `rqrcode ~> 3.2`. Both were in the lockfile under #490 (6.3.0 and 3.2.0) and are maintained. Rails 8.1 has no built-in TOTP. Regenerate the lockfile with `bundle install`.

## Sign-in with the authenticator on

1. `POST /login` and `POST /login/code` work as now.
2. **When the emailed code is right and the account has the authenticator on,** `SessionsController#verify_code` does not sign in. Instead:
   - Under the row lock it issues a challenge: `second_factor_challenge_at = now` and `second_factor_challenge_failures = 0`.
   - It stores `session[:pending_second_factor] = { "user_id" => id, "at" => second_factor_challenge_at }` and redirects to `GET /login/second-factor`.
   - The cookie only says which challenge this browser holds. Its count of wrong codes lives on the row.
   - It leaves `return_to` and any pending trial where they are.
   - The emailed code has already been used, so a second sign-in needs a new one.
3. **`GET /login/second-factor`** shows one field: "Code from your authenticator app, or a recovery code".
4. **`POST /login/second-factor`** runs `verify_second_factor!`.
   - **On success:** read the pending trial and `return_to`, run `reset_session` (through `start_new_session_for`), set `session[:user_id]` and `session[:signed_in_at]`, then redirect as sign-in does now.
   - **After a recovery code,** the notice says how many recovery codes are left.
5. **The pending marker expires after 5 minutes.**
   - A marker counts only when its `at` equals the row's `second_factor_challenge_at` and that time is under 5 minutes old.
   - Each wrong code adds one to `second_factor_challenge_failures` under the row lock. At 5, the row's `second_factor_challenge_at` is cleared, so every copy of the cookie stops working at once.
   - Success also clears it. So do expiry and the daily cap.
   - Each of those sends the user back to `/login` for a new emailed code.
   - Replaying an earlier copy of the cookie gets back the same challenge, not a new count. Only a correct emailed code issues a new challenge.
   - It never counts as signed in: `current_user` reads only `session[:user_id]`, so the cable connection and every page treat a pending session as signed out.
6. **Accounts with the authenticator off** sign in exactly as now. `start_new_session_for` also sets `session[:signed_in_at]` for them, so decision 3 works.

**Rate limits** use `rate_limit` and `LazyCacheStore`, with their own `name:` and over `User::LOGIN_RATE_LIMIT_WINDOW`:
- 10 second-factor attempts per pending account;
- 20 per IP;
- 10 per account for turning the authenticator on, turning it off and making new codes, together.

The per-challenge limit of 5 wrong codes (step 5) and the daily cap of 20 failures (decision 8) sit under these. Both are counted on the row.

**When the daily cap is reached,** the second-factor page, turning the authenticator off and making new codes all show the same message. It says the account has had too many wrong codes, and when it can try again. Each of these pages accepts nothing until then.

## Setup on the Account page

Add a section to the Account page, `/account`.

**When it's off:**
- "Add an authenticator app" leads to `GET /account/authenticator`.
- With an old sign-in (decision 3), the page says to sign in again. Its button signs out, saves `return_to` as this page, and goes to `/login`.

**The setup page shows three things, in this order:**
1. **"Open in authenticator app."** This is a link to `otpauth://totp/Code%20Gym:<email>?secret=<base32>&issuer=Code%20Gym&algorithm=SHA1&digits=6&period=30`, built by `ROTP::TOTP#provisioning_uri`. On a phone, the authenticator is on the same device as this page, so a link that opens it is the main path.
2. **The setup key as text,** in groups of four, with a "Copy" button. The button is a Stimulus controller using `navigator.clipboard`. This is the fallback when the link doesn't open the app, which can happen from an installed iOS PWA.
   - When the clipboard is missing or the write is refused, the controller selects the key so it can be copied by hand, and says so.
3. **A QR code,** for setting up a phone from a desktop. It's an inline SVG from `RQRCode::QRCode#as_svg`, so it needs no script and passes the CSP.

Below them is "Enter the 6-digit code your app shows" (field `otp_code`) and "Turn on" (`POST /account/authenticator`).

- **On success** the page shows the ten recovery codes once, with a "Copy all" button and the advice to keep them outside the phone.
- **A second submit** goes to `/account`, which says the authenticator is already on.

**`Cache-Control: no-store`.** The setup page sends it, and so does every response that shows recovery codes: turning the authenticator on, and making new codes. Neither the browser's cache nor its back-forward cache then keeps a copy, so the back button can't show a "shown once" page again. Put the header in a `before_action` or a one-line helper that both controllers call, so it's stated once.

**When it's on**, the Account page shows when it was turned on and how many recovery codes are left, plus two forms. Each takes an authenticator or recovery code:
- "Make new recovery codes" (`POST /account/recovery_codes`) shows the new set once and voids the old.
- "Turn off the authenticator" (`DELETE /account/authenticator`).

**Moving to a new phone** is "turn off, then add again". It needs no separate flow.

**Views** follow the existing patterns:
- Stimulus controllers only, with no inline scripts.
- Text in `config/locales/en.yml` under new keys.
- The layout must fit a 320px screen with the largest text size (`small_screen_layout_spec`).

## Recovery

- **Lost phone, codes kept:** sign in with the emailed code and then a recovery code. Then turn the authenticator off and add it again on the new phone.
- **Lost phone and codes:** from a Rails console on production `web`, run `User.find_by!(email: "…").update!(two_factor_enabled_at: nil, otp_secret: nil, consumed_timestep: nil, otp_backup_codes: nil, second_factor_failures: 0, second_factor_failures_since: nil, second_factor_challenge_at: nil, second_factor_challenge_failures: 0)`. Then sign in with the emailed code. The decision doc carries this line.
- **Locked by the daily cap, with the phone in hand:** wait out the window, or clear the cap from the console: `update!(second_factor_failures: 0, second_factor_failures_since: nil)`.
- **The emailed code never removes the second factor.** Only a code from the authenticator, a recovery code, or the console can.

## Keeping the secret and the codes out of logs

- **Parameters.**
  - Every field that takes a second-factor or recovery code is named `otp_code`.
  - `config/initializers/filter_parameter_logging.rb` already filters `:otp`, as a substring, and `:secret`, so `otp_code`, `otp_secret` and `otp_backup_codes` read `[FILTERED]` in request logs and in Active Record `inspect`.
  - `encrypts :otp_secret` also adds the column to the filter by default.
  - A spec pins this, so the field can't be renamed out of the filter. No new entry is added, since a second rule naming the same field could drift from the first.
- **The setup key and the `otpauth://` link** exist only in the rendered page.
  - Rails logs no response bodies.
  - No code passes the secret to `Rails.logger`, to an exception message or to a mailer.
  - The change notices say what changed, never the key or a code.
- **Error reports.** The app has no error-reporting service and doesn't call `Rails.error`. An unhandled error reaches only the log, as its message and backtrace, and the rule above covers that. If a reporter is added later, it should use `config.filter_parameters` too.

## Stated plainly

- **Opt-in,** including for admins. `/admin/judge_solves` is single-factor for any admin who hasn't turned it on.
- **The inbox can still lock you out.** Whoever controls the inbox can't get past the second factor, but they can still request codes and use up the per-address limits.
- **They can also lock you out of signing in for a day.** They pass the emailed step, then send 20 wrong codes, and the daily cap refuses everything, recovery codes included. The console is the way back in sooner.
- **A phone that holds the email, the authenticator and an open session** is one factor in practice.
- **The deploy signs everyone out once,** because no session made before it has `signed_in_at`.

## Specs

**Model** (`spec/models/concerns/second_factor_spec.rb`):
- **Codes accepted and rejected:**
  - The current step's code is accepted, and so is the step either side.
  - Two steps away is refused.
  - The same code is refused a second time (`consumed_timestep`).
- **Recovery codes:**
  - A recovery code works once.
  - Codes compare case-insensitively and ignore spaces and dashes.
  - Only input shaped like a recovery code (10 characters from the 32-letter alphabet) is compared against the digests. A 6-digit input is checked as a TOTP only, with no bcrypt comparison, so a wrong guess never holds the row lock through ten of them.
  - A digest never equals its code.
- **Turning it on and off:**
  - `enable_second_factor!` needs a valid code for the pending secret.
  - A second call returns `:already_on` and makes no new codes.
  - Off clears all four columns.
- **Locking:** two instances of one user submitting the same code produce one success.
- **Session validity** (`session_signed_in_valid?`):
  - A missing or unreadable `signed_in_at` is refused.
  - A time earlier than `sessions_valid_after` is refused.
  - The same time, or later, is accepted.
  - With `sessions_valid_after` nil, any present time is accepted.
- **Encryption:** `otp_secret` is stored encrypted; the raw column value differs from the secret.
- **The daily cap:**
  - After 20 failures within 24 hours, a correct TOTP and an unused recovery code both get `:locked`.
  - 24 hours after the first failure, a correct code works again.
  - Successes never add to the count.
  - The cap is shared by the sign-in step, turning the authenticator off and making new codes.

**Requests:**
- **Sign-in with the authenticator on:**
  - The right emailed code leads to the second-factor page, and the session holds no `user_id`.
  - A right TOTP signs in and runs the full `reset_session`: only `user_id`, `signed_in_at`, `flash` and `_csrf_token` remain.
  - A recovery code signs in and reports how many are left.
  - A wrong code re-renders the page.
  - Five wrong codes drop the marker, and the row's challenge is cleared.
  - **Replaying an old cookie doesn't reset the count.** Copy the session cookie right after the challenge is issued, then send four wrong codes. Put the earlier copy back and send a fifth. The challenge must end at that fifth code, not start counting again from zero.
  - An expired marker sends the user to `/login`.
  - `return_to` and a pending trial survive the second step.
- **Sign-in with the authenticator off:** unchanged, and `signed_in_at` is set.
- **Ending other sessions** (decision 11):
  - Sign in on two sessions, A and B, and turn the authenticator on from A.
  - B is then signed out on its next page request.
  - B's stamp is also refused on the cable connection.
  - A keeps working: its next page loads signed in.
  - Turning the authenticator off from A does the same to a session signed in before that.
  - Making new recovery codes leaves B signed in.
  - A session with no `signed_in_at`, as every session from before this PR has, counts as signed out.
- **Setup:**
  - An old sign-in is asked to sign in again.
  - Turning it on shows ten codes once.
  - The QR SVG and the `otpauth://` link carry the same secret.
  - Turning it off, and making new codes, each need a code.
  - The emailed code is refused for both.
- **Notices:** each of the three changes sends one email, and none of them contains the setup key or a code.
- **Caching:**
  - `GET /account/authenticator` answers with `Cache-Control: no-store`.
  - So do the responses that show recovery codes: turning the authenticator on, and making new codes.
- **Logs:**
  - **Parameters:** a request carrying `otp_code` logs `[FILTERED]` in place of its value. Capture `Rails.logger` with a `StringIO` around the request.
  - **The setup page:** a `GET /account/authenticator` writes neither the base32 secret nor `otpauth://` to the log.
- **Rate limits:** each new limit stops the next attempt, using a memory store as `login_rate_limit_spec` does.

**Cable:**
- a pending second-factor session is rejected;
- so is a session stamped before `sessions_valid_after`;
- so is a session with no `signed_in_at`.

**System:**
- the authenticator turned on through the setup page, using ROTP to make the code;
- sign-in with the second step;
- the setup page at 320px.

**Mutation checks** (break the line, see the spec fail):
- `after:` removed, so codes can be replayed;
- drift widened;
- the recovery digest left in place after use;
- the lock removed;
- the recent-sign-in check removed;
- the pending marker read as signed in;
- the challenge count kept in the session instead of the row (the replay spec fails);
- the daily cap counting successes, or skipping recovery codes;
- `no-store` removed;
- the validity check removed from the cable connection (the cable spec fails);
- `sessions_valid_after` not set on enable (the ending-sessions spec fails).

## Docs

- `docs/decisions/passwordless-sign-in.md`: the second-factor section, decisions 1–11 with the daily cap's arithmetic, and the recovery lines.
- `docs/decisions/login-rate-limits.md`: the new limits.
- `.claude/rules/accounts.md`, `.claude/rules/models.md` and `docs/file-map.md`.
- Code notes for the concern and the new controllers.

## Merge conditions

- #491 is merged and its post-deploy check has passed.
- CI is green.
- **Checked on a real phone, over `bin/dev` on the local network:** the `otpauth://` link opens an authenticator from Safari on iOS and from Chrome on Android. The PR description records what happened.
- **Checked after merge, on production over HTTPS:** the link from the installed iOS PWA, and the Copy buttons.
  - `navigator.clipboard` needs a secure context, which a plain-HTTP address on the local network isn't.
  - The installed PWA belongs to production's address.
  - Neither blocks the merge, since the visible setup key is the fallback.

## After merge

1. Turn the authenticator on for your account, save the recovery codes, sign out, and sign in with the second step.
2. On production over HTTPS, check the `otpauth://` link from the installed iOS PWA, and the Copy and Copy all buttons.
3. Sign in once with a recovery code, then make a new set.

## Not in this PR

- Passkeys (WebAuthn).
- "Remember this device".
- Requiring the authenticator for admins.
- Trusted proxies: still required before going public, as #491 records.
