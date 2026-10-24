# PR 1 spec: remove Devise and restore passwordless sign-in

Written 2026-10-23 against origin/main at `2d0d469e`. #490 is the squash commit `c7a500c0`, and everything below "pre-#490" refers to `c7a500c0^`.

## Two corrections to the brief

Both are now settled; see "Decisions" at the end.

**1. Before #490, the account was created when the code was requested, not when it was redeemed.**

`LoginCodeRequests#mail_login_code` called `User.active.find_by(email:) || User.create!(...)`, then mailed the code (`app/controllers/concerns/login_code_requests.rb:31-33` at `c7a500c0^`). The 50-per-IP daily cap bounds that creation.

"Exactly as before #490" and "created on the first successful code" are two different designs. Creating the account on the first successful code would leave no user row to hold the code digest, the attempt counter and the row lock that makes a code single-use (`User.authenticate_login_code`). That state would need a new table or a place in the session, which is new design work.

"Exactly as before" was the intent. The row is created at request time, as the revert gives. An unredeemed request leaves an inert account row with no key, no session and no sets, which costs nothing with one account.

**2. `User::LOGIN_CODE_EXPIRY` is also the window of three rate limits.**

The pre-#490 code uses it as the `within:` of three limits:

- 5 requests per address (`login_code_requests.rb:11`)
- 20 requests per IP (`login_code_requests.rb:14`)
- 10 submissions per IP (`sessions_controller.rb:13`)

Shortening the expiry to 10 minutes would therefore also shorten those windows, loosening each limit by half again.

So those three limits get their own constant, `User::LOGIN_RATE_LIMIT_WINDOW = 15.minutes`, and only the code's life drops to 10 minutes. The per-address limit's comment ("stop fresh codes resetting the guess limit") still holds with a window longer than the code's life.

## Context

- I am the only account. Every risk judgement below assumes that.
- Sign-up is open, as before #490:
  - someone enters an email, gets a code, and is signed in;
  - there is no password, no separate sign-up form and no confirmation step;
  - the per-IP daily cap applies.

## Stated plainly

- **No second factor until PR 2.** My account has no second factor until PR 2, by choice. Whoever controls my inbox controls the account.
- **The admin page is single-factor until PR 2.** `/admin/judge_solves` shows answer keys, and until PR 2 it is protected only by the emailed code (`Admin::BaseController#require_admin!` checks the address against the admin list).
- **The two-release column drop protects nothing here, so this PR drops the columns directly.** `.claude/rules/deployment.md` asks a removed column to be ignored for a release before it is dropped. That covers the moment the old code is still running after the drop migration. Here the old code is Devise on one account. Normally the window is the seconds between the web pre-deploy migration and the new release taking traffic, and a failed request from me is the cost. The worst case, a new release that never gets healthy, is written down under "Accepted failure case". Doing it the long way would cost two releases to undo a change made tonight.
- **I'll be signed out once.** The session key goes from Warden's `warden.user.user.key` back to `session[:user_id]`. The cookie name `_code_gym_rails_session` does not change.

## Scope

### 1. Start from a revert of #490

- Run `git revert c7a500c0` on main.
- It conflicts only in `config/locales/en.yml`. Main's `admin.judge_solves` block (from #488) sits next to #490's `devise:` block. Keep the judge-solves block and drop the `devise:` block.
- Then put back what the revert should not remove:
  - **The migration file.** Restore `db/migrate/20261023090000_add_devise_and_two_factor_to_users.rb` unchanged; production has run it. Never edit or delete a pushed migration (`deployment.md`).
  - **The intent log.** The revert takes #490's lines out of `docs/intent/hmccutchen.md`. Keep them, add this PR's line, and run `compose.rb`.
- The revert restores the following, and each should be checked against today's main:
  - `SessionsController` and `LoginCodeRequests`;
  - `require_login`, `current_user` and `logged_in?`;
  - the old `login_as`, the cable connection, `PreviewAutoLogin`, `PreviewSeed` and `TrialsController`;
  - the old views, locale keys and docs.
- No file outside #490's own list references Devise, Warden, `SPEC_PASSWORD` or `enroll_two_factor`. The admin controllers merged afterwards use only `current_user`.

### 2. Drop the Devise columns in a new migration

Add `RemoveDeviseColumnsFromUsers`, timestamped after `20261023090000`. Write each `remove_column` with its type, so the migration can be rolled back.

| Column | Action |
|---|---|
| `encrypted_password` | drop (`string`, `null: false`, `default: ""`) |
| `reset_password_token` | drop; its unique index goes with it |
| `reset_password_sent_at` | drop |
| `confirmation_token` | drop; its unique index goes with it |
| `confirmed_at` | drop |
| `confirmation_sent_at` | drop |
| `otp_secret` | keep for PR 2 |
| `consumed_timestep` | keep for PR 2 |
| `otp_backup_codes` | keep for PR 2 |
| `otp_required_for_login` | leave untouched; PR 2 drops or renames it with the rest of its design. Nothing in PR 1 reads it. |

More details for this step:

- **`schema.rb`.** Regenerate it by running the migrations on Postgres 18, which CI runs. An older local Postgres prints `judge_solves`' check constraints differently, so don't commit a dump from one.
- **`otp_secret`.** It keeps its encrypted contents. With `encrypts :otp_secret` gone, nothing reads it, and nothing in this PR should write to it.
- **`User#anonymize!`.** It currently clears the OTP columns through `sign_in_credentials_cleared`, which the revert removes. Keep clearing `otp_secret`, `consumed_timestep` and `otp_backup_codes` in `anonymize!`, so that deleting the account doesn't leave a secret behind.

### 3. Gems

- The revert removes `devise`, `devise-two-factor` and `rqrcode`. Regenerate `Gemfile.lock` with `bundle install`; don't edit it by hand.
- `warden`, `rotp`, `orm_adapter` and `responders` go with them. PR 2 adds `rotp` and `rqrcode` back directly.

### 4. What Warden provided, and what replaces it

| Warden / Devise | Replacement (restored by the revert) |
|---|---|
| `authenticate_user!` | `ApplicationController#require_login` |
| `current_user`, `user_signed_in?` | `current_user` (`User.active.find_by(id: session[:user_id])`) and `logged_in?` |
| New session id at sign-in | `SessionsController#start_new_session_for` calls `reset_session` |
| Fresh CSRF token at sign-in | `reset_session` drops `session[:_csrf_token]`, so the next form gets a new one |
| `SignInFailureApp` (signed-out JSON → `/login`) | `require_login` uses `redirect_to login_path` for every format. `request.js` treats `response.redirected` as signed out (`app/javascript/code_gym/request.js:35-37`). |
| `env["warden"]` in `ApplicationCable::Connection` | `request.session[:user_id]` |
| Warden test mode in `login_as` | `login_as` posts to `/login` and `/login/code` with a freshly minted code |

**Fix while restoring `require_login`.** It sets `session[:return_to] = request.fullpath` for every request. A dashboard poll that hits an expired session therefore saves `/dashboard/status` as the return address, and the next sign-in lands on a JSON page. Save `return_to` only for HTML GET requests.

**A full session reset at sign-in.** The sign-in audit found that #490 dropped `reset_session` before the session is assigned. The full `reset_session` in `start_new_session_for` (`app/controllers/sessions_controller.rb:101-106` at `c7a500c0^`) restores it. Warden only changed the session id and kept the old data.

**Read before reset.** `take_pending_trial` and `return_to` are read before the reset, as the old code did.

### 5. Code expiry

- `User::LOGIN_CODE_EXPIRY = 10.minutes`, with `User::LOGIN_RATE_LIMIT_WINDOW = 15.minutes` as the `within:` of the three limits named in correction 2.
- The email and the notice read the expiry through `User.login_code_expiry_in_words`, so their wording follows automatically.
- Specs that travel past the expiry already use the constant, so they need no change.

### 6. Docs

**Supersede `docs/decisions/password-and-authenticator-sign-in.md`.**

- No decision doc has been superseded before, so there is no convention to follow.
- Keep the file and replace its body with a short note: what #490 did, that this PR reversed it, and why.
- Point the note at a new `docs/decisions/passwordless-sign-in.md` that records:
  - the emailed code as the only first factor;
  - open sign-up, with the account created at request;
  - no passwords, ever;
  - TOTP as an optional second factor, coming in PR 2;
  - the two plain statements above.
- Update the files that link to the old doc:
  - `.claude/rules/accounts.md:44`
  - `docs/decisions/login-rate-limits.md:16`
  - the code notes for `devise.rb`, `first_sign_ins_controller.rb` and `sign_in_credentials.rb`, which the revert deletes along with their code.

**Update `docs/decisions/login-rate-limits.md`.**

- Start from the pre-#490 text, which the revert restores.
- Add the 10-minute code life and the 15-minute limit window.
- Remove the password paragraph.

**Check what the revert restored.** Read `CLAUDE.md`, the README, `docs/file-map.md`, `.claude/rules/{accounts,models,request-flow}.md` and the code notes against the final code.

## Specs

### Already covered once the revert restores them

Confirm each still runs on today's main:

- `spec/requests/sessions_spec.rb`:
  - creates a first-time user; reuses a known one;
  - session rotation on login and logout;
  - `return_to` survives the rotation;
  - stale CSRF token handling;
  - keeps the default cookie key;
  - anonymized users;
  - an expired code.
- `spec/requests/login_rate_limit_spec.rb`, including "stops a 51st request from one IP in a day", which is the per-IP daily cap.
- `spec/system/code_login_spec.rb`, `spec/models/login_code_concurrency_spec.rb`, `spec/channels/application_cable/connection_spec.rb`, `preview_auto_login_spec` and `trials_spec`.

### New

**1. Open sign-up.**

- `POST /login` for an unknown address creates exactly one user and mails a code.
- The first valid code signs that user in.
- A second request for the same address creates no second row.

**2. `reset_session` at sign-in, not just a new id.**

- Read `session[:_csrf_token]` before sign-in.
- After `POST /login/code`, the session's keys are only `user_id`, plus `flash` and `_csrf_token` where present.
- The CSRF token differs from the one read before.
- The pre-sign-in `pending_login_email` and `pending_login_at` are gone.
- A session-id check alone can't tell `reset_session` from Warden's renew, so these key checks are what make this spec matter.

**3. Per-IP daily cap.**

- Already covered by the restored spec, with a memory cache store.
- Add one example showing that the trial form's requests count against the same daily bucket (`LoginCodeRequests::SCOPE`).

**4. Signed-out JSON request.**

- `GET /dashboard/status` with `Accept: application/json` and no session returns 302 with `Location` ending `/login`.
- `session[:return_to]` is not set to the JSON path.
- A signed-out HTML GET still sets it.

**5. Code life.**

- A code redeemed 9 minutes after sending works; at 11 minutes it is refused.
- The rate-limit windows stay at 15 minutes.

**6. Columns.**

- `User.column_names` contains none of the six dropped columns.
- It still contains `otp_secret`, `consumed_timestep` and `otp_backup_codes`.

### Checks before opening the PR

- The unit suite, `spec/system`, RuboCop, `bin/comment-check`, `archspec check` and Brakeman.
- The isolation specs (`trial_isolation_spec`, `level_suggestion_isolation_spec`, `duck_thread_isolation_spec`) should pass unchanged. The restored files read no trial, track or duck state beyond what they read before #490, when the specs passed.

## Deploy

1. The web pre-deploy runs the drop migration before Railway has confirmed the new release is healthy. The old release keeps serving until the new one passes its health check, and that overlap is the window discussed under "Stated plainly".
2. The worker's pre-deploy only waits for a schema; nothing there changes.

### Post-deploy check

Run all four. Each must pass:

1. `/login` loads and asks for an email.
2. The emailed code signs me in.
3. `/dashboard` loads.
4. The six columns are gone from `users`. In a Rails console on `web`, this returns `[]`:

   ```ruby
   User.reset_column_information
   User.column_names & %w[encrypted_password reset_password_token reset_password_sent_at
                           confirmation_token confirmed_at confirmation_sent_at]
   ```

### Accepted failure case

Suppose the new release fails its health check after the migration has run. Then the old Devise release keeps serving against a `users` table with no `encrypted_password`, and sign-in is broken until a fix ships. With one account, that is accepted.

## Not in this PR: trusted proxies (required before posting publicly)

The per-IP limits key on `request.remote_ip`. Nothing on main sets `config.action_dispatch.trusted_proxies`. If Railway's edge address isn't one Rails trusts by default, every request shares one IP, and each per-IP limit becomes a single bucket for everyone.

**The line to check** is Rails' request log line on the `web` service:

```
[<request id>] Started GET "/login" for <IP> at <time>
```

**What production shows today.** On 2026-10-23 these lines show many different public addresses for different visitors (scanners, among others), such as `152.233.x.x` and `79.127.x.x`. That suggests `remote_ip` is already the client's address. It isn't proof.

**To confirm:**

1. From your phone on mobile data, open `/login`.
2. Look up the IP that request logged.
3. Compare it with the public IP your phone reports on a "what is my IP" page.
4. Repeat from your laptop on Wi-Fi.
5. **Spoof test.** Matching IPs show that Rails finds the client's address, but not that a client can't fake it. From the laptop, run:

   ```
   curl -H "X-Forwarded-For: 1.2.3.4" https://<host>/login
   ```

   Then check that the logged line shows the laptop's real IP, not `1.2.3.4`.

| Result | Meaning |
|---|---|
| Each logged IP matches its device, and the spoof test logs the real IP | No change needed. Record both results in `docs/decisions/login-rate-limits.md`. |
| Both devices log the same address, or a private one (`10.x`, `100.64.x`–`100.127.x`, `172.16.x`) | Every per-IP limit is one shared bucket. Configure trusted proxies before going public. |
| The spoof test logs `1.2.3.4` | Anyone can dodge every per-IP limit by changing a header. Configure trusted proxies before going public. |

## Decisions

1. **The account is created when a code is requested,** as before #490. A first valid code signs in an existing row; it never creates one.
2. **The rate-limit windows stay at 15 minutes** under `User::LOGIN_RATE_LIMIT_WINDOW`. Only the code's life drops to 10 minutes.
3. **`otp_required_for_login` is left untouched** for PR 2 to drop or rename.
4. **`return_to` is saved only for HTML GET requests,** fixed while restoring `require_login`.
