# Implementation plan: an optional authenticator app as a second factor

This plan builds `docs/optional-totp-spec-2026-10-23.md`, the PR 2 spec. It is one PR on `claude/clever-allen-ku6296-totp`, stacked on #491's branch. When #491 merges, the PR is retargeted to `main` with `main` merged in, before it merges itself.

Work it in the order below. Each step is a commit that passes its own specs, so the branch stays green throughout. Paths and line numbers are as of #491's head, `bf03e2f1`. Follow `main` if #491 changes before it merges.

**Merge conditions:**
- #491 is merged, and its post-deploy check has passed.
- CI is green on the final head: RSpec, system specs, lint (RuboCop, `bin/comment-check`, `archspec check`), Brakeman and `importmap audit`.
- Every mutation in step 10 fails its spec.
- The `otpauth://` link opens an authenticator from Safari on iOS and from Chrome on Android, checked over `bin/dev` on the local network (step 0). The PR description records what happened.

The link from the installed iOS PWA, and the Copy and Copy all buttons, are checked after merge on production. A link that doesn't open the app blocks nothing: the setup key is on the page as the fallback, and the outcome only changes what the PR description and docs say.

The post-merge items are listed at the end; they aren't part of this PR.

**Why this order.**
- The columns come first (step 1), then the session check (step 2). Step 2 changes who counts as signed in for every request, so it lands, and is tested, before anything uses it.
- The model (step 3) comes before the pages that call it (steps 4–6).
- The checks against logs and caches (step 7) and the browser specs (step 8) run once the pages exist.

## Step 0. Before writing code

- Branch `claude/clever-allen-ku6296-totp` from #491's head and open the draft PR against #491's branch. #491 must merge first, and this PR is then retargeted to `main`.
- **Confirm the eleven decisions in the spec.** Each step below assumes them.
- **Split the phone check by what each setup can test.**
  - **Before merge, over `bin/dev` on the local network.**
    - PR preview apps still fail to deploy, because PR environments have no `Database` service.
    - So run the branch with `bin/dev -b 0.0.0.0` and open it from the phone on the same Wi-Fi. Plain HTTP is fine for this.
    - Check that the `otpauth://` link opens an authenticator from Safari on iOS and from Chrome on Android.
  - **After merge, on production over HTTPS:**
    - the link from the installed PWA on iOS;
    - the Copy and Copy all buttons.

    Neither can be tested locally. `navigator.clipboard` needs a secure context, and a plain-HTTP address on the local network isn't one. The installed PWA belongs to production's address, not to a local copy.

## Step 1. Columns

**Migration:** `db/migrate/<timestamp>_add_second_factor_columns_to_users.rb`.
- **Add:**
  - `two_factor_enabled_at`: datetime, null;
  - `second_factor_challenge_at`: datetime, null;
  - `second_factor_challenge_failures`: integer, `null: false, default: 0`;
  - `second_factor_failures`: integer, `null: false, default: 0`;
  - `second_factor_failures_since`: datetime, null;
  - `sessions_valid_after`: datetime, null.
- **Remove:** `otp_required_for_login`, `boolean, null: false, default: false`, written with its type so it can be rolled back.
- **Clear:** set the three `otp_*` columns to nil for every row (decision 1), in a `reversible` block whose `up` runs `update_all`. The `down` does nothing, since cleared data can't come back.

**`User#anonymize!`** clears `two_factor_enabled_at`, the four challenge and failure columns, and `sessions_valid_after`, alongside the three `otp_*` columns it already clears.

**`db/schema.rb`:**
- Keep only the version line and the `users` hunk.
- This container's Postgres re-prints `judge_solves`' check constraints differently, as it did on #491.
- CI's schema load on Postgres 18 confirms the file.

**`.claude/rules/models.md`:** the `User` row lists the new columns and drops `otp_required_for_login`.

**Specs:**
- `spec/models/user_spec.rb`:
  - the columns example from #491 now expects the new columns and no `otp_required_for_login`;
  - `#anonymize!` clears every new column.
- `bin/rails db:migrate:redo` locally.
- The full unit suite. Nothing reads the new columns yet.

## Step 2. A session counts only if it was signed in after `sessions_valid_after`

- **`User#session_signed_in_valid?(signed_in_at)`**, the one rule (decision 11):
  - It parses an `iso8601(6)` string and returns false on nil or on an unreadable value.
  - It returns `sessions_valid_after.nil? || time >= sessions_valid_after`.
- **`ApplicationController#current_user`** (`app/controllers/application_controller.rb:39`):
  - Look up `User.active.find_by(id: session[:user_id])`.
  - Then keep the user only if `session_signed_in_valid?(session[:signed_in_at])`.
- **`ApplicationCable::Connection#find_verified_user`** makes the same lookup and the same check, through the same method. Write it once: a class method such as `User.signed_in_through(session)`, called by both. The rule then has one home and the two callers can't drift.
- **Stamping:**
  - `SessionsController#start_new_session_for` (`app/controllers/sessions_controller.rb:101`) sets `session[:signed_in_at] = Time.current.iso8601(6)` after `reset_session`.
  - `PreviewAutoLogin` (`app/controllers/concerns/preview_auto_login.rb:20`) sets `session[:user_id]` directly, so it stamps the same way. Otherwise every preview sign-in would count as signed out.
- **`spec/requests/sessions_spec.rb:241`:** the session-reset example now expects `user_id` and `signed_in_at` as the only keys left after sign-in.

**Specs:**
- `spec/models/user_spec.rb`, for `session_signed_in_valid?`:
  - a missing or unreadable value is refused;
  - a time earlier than `sessions_valid_after` is refused;
  - the same time or a later one is accepted;
  - with the column nil, any present time is accepted.
- `spec/requests/require_login_spec.rb`, or a new `session_validity_spec.rb`:
  - A signed-in session with `sessions_valid_after` set later (with `update_column`) is redirected to `/login` on its next page.
  - A session with no `signed_in_at`, as every session from before this PR has, is redirected too.
- `spec/channels/application_cable/connection_spec.rb`:
  - A session with no `signed_in_at` is rejected.
  - So is a session stamped before `sessions_valid_after`.
  - A current stamp is accepted.
- `spec/requests/preview_auto_login_spec.rb`: auto-login still lands signed in.
- The full unit suite and `spec/system`, since `current_user` and `auth_helpers` run under every request and system spec.

**Mutation checks:**
- Remove the check from the cable connection: the connection spec fails.
- Leave the stamp out of `PreviewAutoLogin`: its spec fails.

## Step 3. The `SecondFactor` model

**Gems:** add `rotp ~> 6.3` and `rqrcode ~> 3.2` to the `Gemfile`, then `bundle install`. Don't edit the lockfile by hand.

**`app/models/concerns/second_factor.rb`**, included by `User`:
- `encrypts :otp_secret`.
- **Constants:**
  - `SECOND_FACTOR_DAILY_FAILURES = 20`;
  - `SECOND_FACTOR_CHALLENGE_FAILURES = 5`;
  - `SECOND_FACTOR_CHALLENGE_LIFETIME = 5.minutes`;
  - `RECOVERY_CODE_COUNT = 10`;
  - `RECENT_SIGN_IN = 15.minutes`.
- **`Outcome`:** a `Data` value carrying `status`, `recovery_codes`, `changed_at` and `remaining`. Each method returns one.
- **Methods:**
  - `two_factor_enabled?`;
  - `prepare_second_factor!`;
  - `enable_second_factor!(code)`;
  - `verify_second_factor!(code)`;
  - `regenerate_recovery_codes!(code)`;
  - `disable_second_factor!(code)`.

  Each writing method runs under `with_lock`, as the spec's "Model" section describes. `enable_second_factor!` and `disable_second_factor!` set `sessions_valid_after` to the same `now` they return as `changed_at`.
- **Small pure helpers** (`totp_for(secret)`, `normalize_code`, `recovery_code_digests`), each named for what it does, so no method passes 25 lines.
- **Recovery codes:** made with `SecureRandom` from the 32-letter alphabet, in two groups of five. Stored as `BCrypt::Password.create`, and compared after removing spaces and dashes and upcasing.
- **Telling the two kinds of code apart by shape.** `verify_second_factor!` normalizes the input first. Then:
  - 10 characters, all from the 32-letter alphabet: compare against the recovery digests only.
  - Anything else, including every 6-digit input: check the TOTP only, with no bcrypt comparison.
  - The two shapes can't overlap. The alphabet has no `0` or `1`, and a TOTP is six digits.
- **Cost of checking:**
  - A 6-digit guess, right or wrong, costs one TOTP check, so it never holds the row lock for longer than that.
  - Only recovery-shaped input pays for bcrypt: up to ten comparisons, about 0.25 seconds each at production cost. That's about 2.5 seconds under the row lock for a wrong recovery-shaped guess.
  - The daily cap of 20 failures bounds how often that can happen. Tests run at minimum cost through `spec/support/bcrypt_cost.rb`.

**Specs** (`spec/models/concerns/second_factor_spec.rb`), everything in the spec's "Model" list:
- codes either side of now, two steps away, and the replay refused;
- each recovery code working once, in any case and spacing;
- a wrong 6-digit code makes no bcrypt comparison (`expect(BCrypt::Password).not_to receive(:new)`), and a recovery-shaped input never reaches the TOTP check;
- turning on and off, including `:already_on`;
- two instances of one user, so the lock lets one submit through;
- `otp_secret` stored encrypted;
- the daily cap:
  - 20 failures lock out a correct TOTP and an unused recovery code;
  - 24 hours later a correct code works again;
  - successes don't count;
- `enable_second_factor!` and `disable_second_factor!` setting `sessions_valid_after` to the outcome's `changed_at`;
- `regenerate_recovery_codes!` leaving it unchanged.

Add helpers to `spec/support/auth_helpers.rb`:
- `enroll_second_factor(user)` turns the authenticator on through the model and returns the secret and the codes;
- `current_totp(secret)`.

## Step 4. The second sign-in step

**`SessionsController#verify_code`:**
- **Authenticator on:** issue a challenge under the row lock. Set `second_factor_challenge_at` and zero `second_factor_challenge_failures`. Store `session[:pending_second_factor]` and redirect to `/login/second-factor`.
- **Authenticator off:** unchanged.
- Keep the method under 25 lines by moving the two branches into named private methods.

**New `SecondFactorChallengesController`**, with `GET` and `POST /login/second-factor`:
- A `before_action` drops a marker that doesn't match the row's `second_factor_challenge_at`, or is older than the lifetime, and redirects to `/login`.
- **`POST`** runs `verify_second_factor!` and maps each outcome:
  - **`:totp` or `:recovery_code`:** read `PendingTrial` and `return_to`, then call `start_new_session_for`. Move it, or a shared helper, into a concern both controllers include. Then redirect as sign-in does now. After a recovery code, the notice gives the count left.
  - **`:rejected`:** add one to `second_factor_challenge_failures` under the lock. At 5, clear the challenge and redirect to `/login`. Otherwise re-render with 422.
  - **`:locked`:** render the daily-cap message with 429, saying when to try again.
- **`rate_limit`** with `LazyCacheStore`, each with its own `name:` and over `User::LOGIN_RATE_LIMIT_WINDOW`:
  - 10 per pending account, keyed by the marker's `user_id`;
  - 20 per IP.

**Views and locales:**
- `app/views/second_factor_challenges/new.html.erb` has one field, `otp_code`, with `inputmode`, `autocomplete="one-time-code"` and no autofocus.
- New keys under `second_factor_challenges` in `en.yml`.

**Routes:** add both, each with its route comment.

**Specs** (`spec/requests/second_factor_challenges_spec.rb`), from the spec's "Sign-in with the authenticator on" list:
- the emailed code leading here with no `user_id`;
- a TOTP and a recovery code each signing in, with the full reset;
- a wrong code re-rendering;
- five wrong codes clearing the row's challenge;
- **the cookie replay:**
  - save `cookies[...]` after the challenge is issued;
  - send four wrong codes;
  - restore the saved cookie;
  - one more wrong code ends the challenge;
- an expired marker sent to `/login`;
- `return_to` and a pending trial surviving;
- the daily cap message;
- both rate limits, with a memory store.

**Also:**
- `spec/channels/application_cable/connection_spec.rb`: a pending marker with no `user_id` is rejected.
- `spec/requests/sessions_spec.rb`: an account with the authenticator off signs in as before.

**Mutation checks:**
- Keep the challenge count in the session instead: the replay spec fails.
- Read the marker as signed in: the "no `user_id`" spec fails.

## Step 5. Turning the authenticator on and off

**New `AuthenticatorsController`**, `resource :authenticator` under `/account`, with `show`, `create` and `destroy`:
- **`show`:**
  - Signed in more than `RECENT_SIGN_IN` ago, judged from `session[:signed_in_at]`: render the "sign in again" page. Its button signs out, saves `return_to` as this page, and goes to `/login`.
  - Otherwise call `prepare_second_factor!` and render the setup page:
    - the `otpauth://` link, built by `ROTP::TOTP#provisioning_uri` with `issuer: "Code Gym"`;
    - the setup key in groups of four, with a Copy button;
    - the QR code as inline SVG.
  - With the authenticator already on, redirect to `/account`.
- **`create`:** the same recent-sign-in check, then `enable_second_factor!`.
  - **On success:** write the outcome's `changed_at` into `session[:signed_in_at]` and render the recovery codes.
  - **`:already_on`:** redirect to `/account`.
  - **`:rejected`:** re-render with 422.
- **`destroy`:** `disable_second_factor!`.
  - **On success:** re-stamp the session the same way and redirect to `/account`.
  - **`:rejected`:** redirect back with the message.
  - **`:locked`:** the daily-cap message.
- **`Cache-Control: no-store`** on `show` and on the response that shows the codes. Put it in one private method, such as `forbid_caching`, in a small concern that step 6's controller includes too.
- **`rate_limit`:** 10 per account, over `LOGIN_RATE_LIMIT_WINDOW`. One `name:` is shared with step 6, so turning on, turning off and making new codes count together.

**`app/helpers/authenticator_setups_helper.rb`:** builds `qr_code_svg(uri)` and `grouped_key(secret)`.

**Stimulus:** `app/javascript/controllers/copy_text_controller.js` copies its target's text with `navigator.clipboard.writeText`. Use it for the key and for "Copy all" on the codes. It sends nothing to the server, so no request goes through `request.js`.

**Fallback when copying fails.** `navigator.clipboard` can be missing outside a secure context, or `writeText` can be rejected. In either case the controller:
- selects the target's text with a `Range` on the element, so it can be copied by hand;
- shows a short message from a `data-` value rendered from the locale file, such as "Selected. Copy it with your device's copy command."

Success shows "Copied". Both messages go in a polite live region next to the button.

**Account page:** add a section rendering `accounts/_authenticator.html.erb`.
- **Off:** an "Add an authenticator app" link.
- **On:** the date it was turned on, the count of codes left, and two forms using `otp_code`: "Make new recovery codes" and "Turn off".
- Its CSS stacks the forms at 320px.

**Mailer:** `UserMailer#second_factor_changed(user, change)`, with `change` as `:enabled`, `:disabled` or `:recovery_codes`. One template says what changed, when, and what to do if it wasn't you. It never includes the key or a code. It is sent after the change commits.

**Specs** (`spec/requests/authenticators_spec.rb`):
- an old sign-in shown the "sign in again" page;
- a recent one shown the setup page, whose QR SVG and `otpauth://` link carry the same secret;
- turning on showing ten codes once, and a second submit going to `/account`;
- turning off needing a code, with the emailed code refused;
- **ending other sessions** (decision 11):
  - sign in two sessions with `open_session`, A and B;
  - turn on from A;
  - B is redirected to `/login` on its next page, and its stamp is refused by the cable connection;
  - A's next page loads signed in;
  - turning off from A does the same to a session signed in before that;
- `no-store` on `show` and on the response with the codes;
- one notice per change, containing neither the key nor any code;
- the shared rate limit.

**Mutation checks:**
- Remove the selection fallback: step 8's fallback system spec fails.
- Don't set `sessions_valid_after` on enable: the ending-sessions spec fails.
- Remove the re-stamp: A's "loads signed in" fails.
- Remove the recent-sign-in check, or `no-store`: their specs fail.

## Step 6. Making new recovery codes

**New `RecoveryCodesController#create`** (`POST /account/recovery_codes`):
- `regenerate_recovery_codes!`, then:
  - **On success:** render the new codes with `no-store`;
  - **`:rejected`:** redirect back with the message;
  - **`:locked`:** the daily-cap message.
- It sends the `:recovery_codes` notice.
- It doesn't touch `sessions_valid_after` or the session stamp.
- It includes step 5's caching concern and shares its rate-limit name.

**Specs** (`spec/requests/recovery_codes_spec.rb`):
- the new set shown once, and the old set no longer working;
- the emailed code refused;
- another signed-in session staying signed in;
- `no-store`;
- one notice;
- the shared rate limit counting it.

## Step 7. Logs

**Specs** (`spec/requests/second_factor_logging_spec.rb`):
- **Parameters:**
  - Point `Rails.logger` at a `StringIO` around the request.
  - A `POST /login/second-factor` with `otp_code: "123456"` logs `[FILTERED]` and never `123456`.
  - The same holds for `POST /account/authenticator`.
- **The setup page:** a `GET /account/authenticator` logs neither the base32 secret nor `otpauth://`.
- **The model:** `user.inspect` shows `[FILTERED]` for `otp_secret` and `otp_backup_codes`.

No app change is expected. The existing `:otp` filter covers `otp_code`, `otp_secret` and `otp_backup_codes`. These specs pin that, so a renamed field fails one.

**Mutation check:** rename the field to `second_code` in one form, and the parameter spec fails.

## Step 8. Browser specs

**`spec/system/second_factor_spec.rb`:**
- Sign in, turn the authenticator on through the setup page, with ROTP making the code, and see the ten codes.
- Sign out, then sign in again through the second step.
- Sign in with a recovery code.
- Turn the authenticator off.
- **Copy fallback:**
  - Stub `navigator.clipboard` away, by defining it as `undefined` before the click with `page.execute_script`.
  - Click Copy, then check that `window.getSelection().toString()` equals the setup key and the fallback message shows.
  - Run a second example with `writeText` stubbed to reject; it ends the same way.

**`spec/system/small_screen_layout_spec.rb`:** add the setup page, the recovery-codes page and the second-factor page at 320px with the largest text.

**Specs:** these two files, then `spec/system` once.

## Step 9. Docs

- **`docs/decisions/passwordless-sign-in.md`:**
  - the second-factor section, with decisions 1–11, the daily cap's arithmetic, and session ending;
  - the recovery lines, including clearing the cap;
  - "Stated plainly", with the inbox holder able to lock me out for a day, and the deploy signing everyone out once.
- **`docs/decisions/login-rate-limits.md`:** the second-factor limits, the per-challenge limit, and the daily cap.
- **`.claude/rules/accounts.md`:** a "Second factor" entry, and the session-validity rule as a must-not-break.
- **`docs/file-map.md`:** the new files.
- **Code notes:**
  - `app/models/concerns/second_factor.md`: the drift, `after:`, the daily cap's numbers, and why the counts live on the row;
  - `app/controllers/second_factor_challenges_controller.md`;
  - `app/controllers/authenticators_controller.md`: the re-stamp and `no-store`.

**Specs:** `spec/conventions`, `bin/comment-check`.

## Step 10. Checks, the PR description and the intent log

**Checks:**
- `bundle exec rubocop`, `bin/comment-check`, `bundle exec archspec check`, `bin/brakeman` and `bin/importmap audit`.
- The full unit suite, then `spec/system` once.
- The isolation specs pass untouched. The concern reads no trial, track or duck state.
- Grep the diff for dead locals, since `Lint/UselessAssignment` is off.
- **Every mutation in the spec's list:**
  - `after:` removed;
  - drift widened;
  - a recovery digest kept after use;
  - the lock removed;
  - the recent-sign-in check removed;
  - the marker read as signed in;
  - the count kept in the session;
  - the cap counting successes, or skipping recovery codes;
  - `no-store` removed;
  - the cable check removed;
  - `sessions_valid_after` not set on enable.

  Break each line, see its spec fail, and restore the file from a scratchpad copy.

**PR description:**
- what was built;
- the eleven decisions;
- the daily cap's arithmetic;
- "Stated plainly";
- the deploy signing everyone out once;
- the results of the local-network phone check, and which checks wait for production and why;
- the mutation list.

**Intent log:** add the entry when the PR opens. Retag it bare just before merging, then run `compose.rb`.

## After merge (not this PR)

1. **The deploy signs you out once,** since no earlier session has `signed_in_at`. Sign in with the emailed code.
2. **Turn the authenticator on** for your account, and save the recovery codes outside the phone.
3. **Sign out, and sign in through the second step.**
4. **Sign in once with a recovery code,** then make a new set.
5. **Check that ending other sessions works:** sign in on a second device, turn the authenticator off and on again from the first, and see the second signed out.
6. **Check on production over HTTPS what the local network couldn't test:**
   - the `otpauth://` link from the installed PWA on iOS;
   - the Copy and Copy all buttons, from Safari and from the installed PWA.

   Record the results in `docs/decisions/passwordless-sign-in.md`. If the link doesn't open the app from the PWA, the doc says the setup key is the way there.
