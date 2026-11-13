---
paths:
  - "app/controllers/{sessions,trials,accounts,application,second_factor_challenges,authenticators,recovery_codes,privacy}_controller.rb"
  - "app/controllers/concerns/{login_code_requests,preview_auto_login,sign_in_completion,authenticator_changes,pending_trial_session,recent_sign_in}.rb"
  - "app/models/{invite_code,pending_trial,provider_credential,trial_allowance,trial_mode,trial_status,house_keys,user,account_data,privacy_notice}.rb"
  - "app/models/concerns/signed_in_sessions.rb"
  - "app/models/user/authenticator.rb"
  - "app/clients/{preview_environment,preview_mail,lazy_cache_store,unfinished_jobs}.rb"
  - "app/services/{preview_seed,account_deletion}.rb"
  - "app/views/{sessions,trials,user_mailer,second_factor_challenges,authenticators,recovery_codes,privacy}/**"
  - "app/views/dashboard/{_trial_banner,_trial_ended}.html.erb"
  - "app/views/accounts/_authenticator.html.erb"
  - "app/helpers/authenticator_setups_helper.rb"
  - "app/mailers/user_mailer.rb"
  - "app/javascript/controllers/copy_text_controller.js"
  - "app/views/api_keys/{_trial_note,_key_guide}.html.erb"
  - "lib/boot/app_host.rb"
  - "script/mint_invite_code.rb"
  - "railway.toml"
  - "spec/**/*{session,login,trial,invite,preview,app_host,account_deletion,user_data_coverage,privacy}*"
---

# Sign-in, trials and preview apps

Each entry states what a change must not break. An entry that names a
`docs/decisions/` doc has its full reasoning, measurements and history there;
read it before changing that area.

- **Invite codes and trials** (`docs/decisions/invite-codes-and-trials.md`):
  An invite code starts a trial on a house key. `InviteCode#redeem!` takes a
  seat in one statement, and the seat is taken only when the emailed code is
  entered. `ProviderCredential.for` picks the key, `TrialAllowance.check!`
  runs before every house-key call, and generation, judges and mastery code
  never read trial state (`trial_isolation_spec`); trial branches render only
  for `User#on_trial?`. Trials are paused: the login page carries no trial
  link, while the routes and gates stay in place.
- **Deleting an account** (`docs/decisions/deleting-an-account.md`):
  `AccountDeletion` removes the `users` row and every row that belongs to
  the person, usage rows included, and gives back the invite seat
  (`User#give_back_invite_seat!`). `AccountData::FATES` is the one list of
  each table's fate, read by the service and by
  `user_data_coverage_spec`, which fails on a table or column that refers
  to a user with no entry; a new one needs the owner's decision before it
  gets a fate. Locks go user, exercises, responses, mastery rows. Work in
  flight writes nothing once the row is gone. `User#anonymize!`,
  `anonymized_at` and `User.active` stay, uncalled by deletion, until the
  accounts anonymized before 2026-11-11 are cleaned up. Deleting needs a
  sign-in within `User::RECENT_SIGN_IN`, the authenticator's check
  (`RecentSignIn`), counted from the sign-in, not the click. An older
  session deletes nothing; this browser's session is reset and comes back
  to Account after the next sign-in, never replaying the DELETE. The cookie
  store keeps a copied cookie valid elsewhere, and the stamp check still
  refuses it.
- **The privacy page**: `GET /privacy` (`PrivacyController`, open signed
  out and to an account with no key) states what Coding Gym keeps, where an
  engineer's work goes and what outlives a deletion; the login page and the
  Account page's delete card link to it. Its text is a set of claims about
  the code, so a change to the behaviour one describes changes the page in
  the same PR: what is stored and for how long, the authenticator secret and
  recovery codes, the key's storage and use, the email Resend sends, the
  answer draft and how long a sign-in lasts, the weekday schedule and the
  unopened-set pause, what the Account page's usage card prices, push
  reminders, what deletion removes, and what outlives it (server logs
  without the email address, the shared concept write-ups, copies outside
  Coding Gym). It states no backups, since they are off. It speaks for the
  app, with no first person. The copy is `privacy.show` in
  `config/locales/en.yml`; every number comes from `PrivacyNotice.facts`,
  and `LOG_DAYS` there must match Railway's log retention
  (`docs/code-notes/app/models/privacy_notice.md`). The page describes the
  behaviour in `docs/decisions/deleting-an-account.md`,
  `per-user-api-keys.md`, `the-duck-thread-is-stored.md`,
  `pausing-generation.md`, `push-reminders.md`, `passwordless-sign-in.md`,
  `login-rate-limits.md`, `what-a-usage-row-records.md`,
  `offline-answer-saving.md` and `the-learn-tab.md`, all under
  `docs/decisions/`.
- **Account usage card**: `/account` shows this calendar month's own-key spend in dollars, a weekday projection held until the 4th, while generation is paused, and whenever a provider has no priced rows, and per-provider dollars from `ApiUsage.own_key_totals` and `MonthlySpend`, in the user's zone. House-key rows stay out, since the account's key did not pay for them, and rows with no price are counted as unpriced (`docs/code-notes/app/models/monthly_spend.md`).
- **Passwordless sign-in** (`docs/decisions/passwordless-sign-in.md`): an
  account signs in with its address and then the emailed code, or the
  authenticator in place of that code once it is on; no password column is
  ever added. A code request creates the account; the code field lives on
  `GET /login/code`, which `GET /login` redirects to while one is pending.
  Sign-in runs `reset_session`
  before setting `session[:user_id]` (`SignInCompletion`), and
  `require_login` saves the return address only for a GET whose `Accept`
  names `text/html`.
- **Session validity**: every sign-in path writes `session[:signed_in_at]`
  with `User.session_stamp`, and a session counts only while that stamp is at
  or after `users.sessions_valid_after`. `current_user` resolves the user
  through `User.signed_in_through`, never a lookup of its own, and passes it
  the two session values rather than the session. No model reads the session or takes it as an argument
  (`app_source_spec`). `User.session_time` is the one reader of a stamp. A new sign-in path that skips the stamp signs its
  users out on their next request.
- **Second factor** (`docs/decisions/passwordless-sign-in.md`): an optional
  authenticator app (`User::Authenticator`). Every read-then-write of its columns
  runs under the user row lock. Every count of wrong codes lives on the row,
  never in the session, and a challenge asked for again within
  `User::Authenticator::DOUBLE_TAP_WINDOW` comes back with its count kept. Recovery-shaped input is compared only against the
  bcrypt digests and anything else only as a TOTP. Turning it on needs a
  sign-in from the last 15 minutes and a code for the setup key, which lives
  only in that browser's session until the code verifies, so no other session
  ever sees the key that gets enrolled; turning it off or making new codes needs
  an authenticator or recovery code, never the emailed code, and with it on
  the emailed code never signs in. Turning it on or
  off sets `sessions_valid_after` and re-stamps the current session. Every
  code field is named `otp_code`, and pages showing the key or codes send
  `no-store`.
- **Emailed-code auth**: No passwords and no links. `User#generate_login_code!`
  mints a 6-digit code, stores a BCrypt digest, and returns the raw code.
  `UserMailer#login_code` calls it while building the email, so the plain code
  is never a job argument, which Solid Queue stores and the enqueue log
  prints; `User.authenticate_login_code` verifies it against the stored
  BCrypt digest, never against the raw code.
  Codes expire in 10 minutes (`User::LOGIN_CODE_EXPIRY`) and die after five
  wrong guesses (`LOGIN_CODE_MAX_ATTEMPTS`). A code is redeemable **only in
  the browser that requested it** — `SessionsController#verify_code` reads the
  address from `session[:pending_login_email]`, never from a form field, so a
  code cannot be pointed at an account this browser did not ask about. That
  binding is why cross-device login is not possible, which is a deliberate
  cost of having one credential instead of two.
- **Login rate limits** (`docs/decisions/login-rate-limits.md`):
  `SessionsController` bounds guessing of the 6-digit code with per-address
  and per-IP `rate_limit`s on code requests and submissions, each over
  `User::LOGIN_RATE_LIMIT_WINDOW` (15 minutes) rather than the code's life. The per-IP
  request caps stop account and mail creation by address rotation; the
  per-address submission cap stops rotating IPs. Each limit needs its own
  `name:`, and `LazyCacheStore` resolves `Rails.cache` per call.
- **Preview apps** (`docs/decisions/preview-apps.md`):
  `PreviewEnvironment.active?`, read from `PREVIEW_APP`, which only
  `railway.toml`'s `[environments.pr.deploy]` sets, is the single authority
  for PR-app seeding, inline mail and auto-login. `PreviewAutoLogin` registers
  only when active and signs in only an account `PreviewSeed.seeded?`
  recognizes as its own. `PREVIEW_APP` must never be set outside PR
  deployments.
- **Host resolution**: `AppHost.resolve` (`lib/boot/app_host.rb`, deliberately
  outside the autoload path because environment files cannot autoload) reads
  `APP_HOST` and Railway's injected `RAILWAY_PUBLIC_DOMAIN`, tolerating either
  with or without a scheme, and **which one wins depends on the environment**.
  Normally `APP_HOST` does, so production's deliberate custom domain always
  beats an injected value. On a preview app (`PREVIEW_APP` set) the order
  inverts, because a PR environment inherits its base environment's variables
  and therefore arrives carrying production's `APP_HOST` — honoring it there
  would give the preview app `default_url_options` pointed at production's host instead of its own. `AppHost` reads that
  variable directly rather than through `PreviewEnvironment`, which is not
  loadable during `Rails.application.configure`; a spec asserts the two names
  agree.
- **No page, email or prompt uses the user's name** (#681): the email on
  Account is enough to say whose account it is. The nav's name field is
  gone, `PATCH /profile` ignores a posted `name`, the emails and the
  welcome-back notice greet no one by name, and the generation prompt
  leaves it out. The `users.name` column is gone (#686): sign-up creates the
  account from the email alone.
