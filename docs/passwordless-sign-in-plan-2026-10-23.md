# Implementation plan: remove Devise and restore passwordless sign-in

This plan builds `docs/passwordless-sign-in-spec-2026-10-23.md` (hmccutchen/code-gym-rails#491). It is one PR from `main`, on the same branch as the spec.

Work it in the order below. Each step is a commit that passes its own specs, so the branch stays green throughout. Paths are as of `main` at `2d0d469e`. #490 is the squash commit `c7a500c0`, and "pre-#490" means `c7a500c0^`.

**Merge conditions:**
- CI is green on the final head: RSpec, system specs, lint (RuboCop, `bin/comment-check`, `archspec check`), Brakeman and `importmap audit`.
- Login-code mail reaches you in production (step 0). After this deploy, the emailed code is the only way in.
- The PR description lists everything in step 8's "PR description".

Everything after the merge is listed at the end and isn't part of this PR.

**Why the revert comes first and the drop comes last.** Step 1 puts the app back on `session[:user_id]` while the Devise columns still exist. Step 7 then drops them. Their separation shows up in two places:
- **On the branch:** each has its own commit and its own green CI run, so a failure in either is pinned to one change.
- **In production:** both ship in one deploy, because the PR squash-merges. The two halves still fail at different points. The drop runs in the web pre-deploy (`bundle exec rails db:migrate preview:seed`, from `railway.toml`) and logs its own `== RemoveDeviseColumnsFromUsers: migrating` lines. The restored code fails, if it does, at boot or at the health check that follows. The deploy log shows which one stopped.

If you want the halves in separate deploys as well, merge steps 0-6 as this PR and ship step 7 as its own small PR. The spec keeps them in one PR, and this plan follows the spec.

## Step 0. Before writing code

- **Rebase risk.** No other PR is open apart from #472, which touches `ApiUsage`, not sign-in. If `main` moves before step 1, re-run the dry-run revert and follow any new conflicts.
- **For you, in production, before merging:** confirm that mail to your address arrives. The deploy signs you out, and the emailed code is then the only way back in.
  - If your account has no password yet, request a code at `/login/first`.
  - If it has one, use "Forgot your password?" at `/password/new`, which sends through the same Resend delivery.
- **Note for later:** the result of this SQL, for the PR description:
  ```sql
  SELECT encrypted_password <> '' AS has_password, otp_required_for_login FROM users;
  ```
  It records what the drop will discard: your password digest, and whether you enrolled an authenticator under #490. The authenticator columns are kept either way.

## Step 1. Revert #490, keeping its migration and columns

**Do:**
1. `git revert --no-commit c7a500c0`.
2. **`config/locales/en.yml` conflict:** keep main's `admin.judge_solves` block, from #488, and drop #490's `devise:` block.
3. **Restore from `main`, since the revert must not remove them:**
   - `db/migrate/20261023090000_add_devise_and_two_factor_to_users.rb`, which production has run;
   - `db/schema.rb`, which keeps the ten #490 columns until step 7;
   - `docs/intent/hmccutchen.md` and `docs/intent-log.md`, which keep #490's line and today's.

   Use `git checkout origin/main -- <path>` for each one. This is a restore during a revert, not undoing a mutation.
4. **`bundle install`.** The revert removes `devise`, `devise-two-factor` and `rqrcode` from the `Gemfile`. Commit whatever `Gemfile.lock` comes out of that, and don't edit it by hand.
5. **Commit message:** say this is a revert of #490 with the migration file, schema and intent log kept.

**What comes back:**
- `SessionsController`, `LoginCodeRequests`, and `require_login`, `current_user` and `logged_in?` in `ApplicationController`;
- the cable connection on `request.session[:user_id]`;
- `login_as` through `/login` and `/login/code`;
- `PreviewAutoLogin`, `PreviewSeed`, `TrialsController`, and the old views, locale keys, docs and specs.

**What to check by hand after the revert:**
- **No Devise references remain:** `grep -rn -i -E "devise|warden|user_signed_in|authenticate_user!" app lib config spec` should be empty.
- **`User` still loads with the extra columns.** `encrypted_password` is `null: false, default: ""`, so `User.create!` without it still works.
- **`RealSource` has `sessions_controller.rb#verify_code` again.** `last_seen_for` matches it by file name and method, so the excerpt's history carries over.

**Specs:** the full unit suite and `spec/system`. `ApplicationController` and `spec/support/auth_helpers.rb` are shared by every request and system spec. Add `rubocop`, `bin/comment-check`, `archspec check` and `bin/brakeman`.

These restored specs have to pass:
- `spec/requests/sessions_spec.rb`, `spec/requests/login_rate_limit_spec.rb`, `spec/requests/trials_spec.rb`, `spec/requests/preview_auto_login_spec.rb`;
- `spec/models/login_code_concurrency_spec.rb`, `spec/channels/application_cable/connection_spec.rb`;
- `spec/system/code_login_spec.rb`.

## Step 2. Pin the restored behavior the spec names

These specs describe code step 1 brought back, so they need no app change. Each one should fail if the line it protects is removed; check that by deleting the line once, then put it back from the scratchpad copy.

- **Open sign-up** (`spec/requests/sessions_spec.rb`):
  - `POST /login` for an unknown address creates exactly one user and mails a code.
  - The first valid code signs that user in.
  - A second request for the same address creates no second row.
- **A full reset at sign-in** (`sessions_spec.rb`, "session rotation on login"):
  - Read `session[:_csrf_token]` before sign-in.
  - After `POST /login/code`, the session holds only `user_id`, plus `flash` and `_csrf_token` where present.
  - The CSRF token differs from the one read before, and `pending_login_email` and `pending_login_at` are gone.
  - The mutation to try: replace `reset_session` with `request.session_options[:renew] = true`. This spec must fail; the existing session-id check would not.
- **Per-IP daily cap shared with the trial form** (`spec/requests/login_rate_limit_spec.rb`): use a memory cache store. 50 requests split between `/login` and `/trial/start` from one IP, then the 51st from either form is refused.

**Specs:** the three files above.

## Step 3. Clear the authenticator columns on account deletion

- **`User#anonymize!`:** add `otp_secret: nil, consumed_timestep: nil, otp_backup_codes: nil` to its `update!`. The step 1 revert removed the version that cleared them (`sign_in_credentials_cleared`).
- `otp_secret` has no `encrypts` now, so writing `nil` to it is a plain column write.
- **Specs:**
  - `spec/models/user_spec.rb`'s `#anonymize!` group, with one new example: a user with an authenticator, after anonymizing, has the three columns nil;
  - `spec/requests/accounts_spec.rb`.

## Step 4. A 10-minute code, with 15-minute limit windows

- **`app/models/user.rb`:**
  - `LOGIN_CODE_EXPIRY = 10.minutes`;
  - add `LOGIN_RATE_LIMIT_WINDOW = 15.minutes`.
- **Use the new constant** as the `within:` of three limits:
  - `LoginCodeRequests`' two 15-minute limits, `code_requests` and `code_requests_by_ip`;
  - `SessionsController`'s `code_attempts`.
- **Leave on `LOGIN_CODE_EXPIRY`:**
  - the pending-login expiry (`pending_login_expired?`);
  - the code check in `User.authenticate_login_code`.
- **Specs:**
  - `spec/models/user_spec.rb`: a code at 9 minutes works, and at 11 minutes it is refused;
  - `spec/requests/login_rate_limit_spec.rb`: a sixth request for one address at minute 12 is still refused, so the window outlasts the code;
  - `spec/requests/sessions_spec.rb`;
  - `spec/mailers/user_mailer_spec.rb`, since the email states the expiry.

## Step 5. `return_to` only for HTML GETs, and the signed-out JSON redirect

- **`ApplicationController#require_login`:** set `session[:return_to] = request.fullpath` only when `request.get? && request.format.html?`. The redirect to `login_path` is unchanged for every format, and it is what `request.js` reads as signed out (`response.redirected`).
- **Specs** (new file `spec/requests/require_login_spec.rb`):
  - Signed out, `GET /dashboard/status` with `Accept: application/json` gets a 302 with `Location` ending `/login`, and `session[:return_to]` is not set.
  - Signed out, an HTML `GET /history` sets `session[:return_to]` to `/history`.
  - A signed-out `POST` sets nothing.
  - After a JSON redirect, signing in lands on the dashboard, not the JSON path.
- **Then:** the full unit suite, since `ApplicationController` is shared.

## Step 6. Docs

- **`docs/decisions/password-and-authenticator-sign-in.md`:**
  - Replace its body with a short "Superseded" note: what #490 did, that #491 reversed it, and why.
  - Link to the new doc below.
  - Keep the file, so old links still resolve.
- **New `docs/decisions/passwordless-sign-in.md`.** It records:
  - the emailed code as the only first factor;
  - open sign-up, with the account created at request;
  - no password column ever;
  - TOTP as an optional second factor in PR 2;
  - that there is no second factor until then, and the admin page is single-factor.
- **`docs/decisions/login-rate-limits.md`:**
  - the pre-#490 text, restored by step 1;
  - the 10-minute code life and the 15-minute window;
  - no password paragraph;
  - a pointer to the trusted-proxy check.
- **Links to the superseded doc** move to the new one: `.claude/rules/accounts.md`, and the code notes that remain after step 1.
- **Read against the code:** `CLAUDE.md`, `README.md`, `docs/file-map.md`, `.claude/rules/{accounts,models,request-flow}.md` and the code notes for `sessions_controller.rb` and `application_controller.rb`. The revert put these back as they were before #490. Correct anything this PR's steps changed since.
- **Specs:**
  - `spec/conventions`, since `claude_rules_spec` checks the rule paths;
  - `spec/prompts/prompt_standards_spec.rb`, since `CLAUDE.md` changes;
  - `bin/comment-check`.

## Step 7. Drop the Devise columns (last)

The app has run on `session[:user_id]` since step 1, with every spec green against the old columns. This step changes only the schema.

- **Migration** `db/migrate/<timestamp after 20261023090000>_remove_devise_columns_from_users.rb`. It runs `remove_column` with the type and options for each column, so it can be rolled back:
  - `encrypted_password`: string, `null: false`, `default: ""`;
  - `reset_password_token`: string;
  - `reset_password_sent_at`: datetime;
  - `confirmation_token`: string;
  - `confirmed_at`: datetime;
  - `confirmation_sent_at`: datetime.

  The two unique indexes go with their columns.
- **Untouched:** `otp_secret`, `consumed_timestep`, `otp_backup_codes` and `otp_required_for_login`.
- **`db/schema.rb`:**
  - Run the migration locally.
  - Keep only the version line and the `users` hunk.
  - Check the dumped `judge_solves` check constraints didn't change. This container's Postgres prints them differently from Postgres 18, which CI and production run.
  - CI's `db:schema:load` then confirms the file.
- **Specs:**
  - a new example in `spec/models/user_spec.rb`: `User.column_names` contains none of the six, and still contains the four kept columns;
  - `bin/rails db:migrate:redo` locally, so the down migration is checked;
  - the full unit suite and `spec/system`.

## Step 8. Checks, the PR description and the intent log

**Checks:**
- `bundle exec rubocop`, `bin/comment-check`, `bundle exec archspec check` and `bin/brakeman`.
- The full unit suite, then `spec/system` once.
- Grep the diff for dead locals, since `Lint/UselessAssignment` is off.
- The isolation specs (`trial_isolation_spec`, `level_suggestion_isolation_spec`, `duck_thread_isolation_spec`) pass untouched.

**PR description:**
- what was reverted, and the three things kept: the migration file, the authenticator columns and the intent log;
- the four decisions;
- the two plain statements: no second factor until PR 2, and the admin page is single-factor;
- why the columns are dropped in this PR, and the accepted failure case;
- the step 0 SQL result;
- the post-deploy check;
- that trusted proxies are split out and required before going public.

**Intent log:** retag `#491 open` as bare `#491` right before merging. Then run `compose.rb`; `check.rb` can't run in this container, because GraphQL is blocked.

## After merge (not this PR)

1. **Post-deploy check:**
   - `/login` loads;
   - the emailed code signs you in;
   - `/dashboard` loads;
   - in a Rails console on `web`, `User.column_names` has none of the six columns.
2. **If the new release never becomes healthy after the migration,** that is the accepted failure case: sign-in is broken until a fix ships. Fix forward. `db:rollback` puts back empty columns, not the dropped data.
3. **Trusted-proxy check, before going public:** matching IPs from phone and laptop, then the `X-Forwarded-For: 1.2.3.4` spoof test, as the spec's table describes.
4. **PR 2:** optional TOTP on `rotp`, reusing `otp_secret`, `consumed_timestep` and `otp_backup_codes`, and deciding the fate of `otp_required_for_login`.
