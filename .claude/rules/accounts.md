---
paths:
  - "app/controllers/{sessions,trials,accounts,application}_controller.rb"
  - "app/controllers/concerns/{login_code_requests,preview_auto_login}.rb"
  - "app/models/{invite_code,pending_trial,provider_credential,trial_allowance,trial_mode,trial_status,house_keys,user}.rb"
  - "app/clients/{preview_environment,preview_mail,lazy_cache_store}.rb"
  - "app/services/preview_seed.rb"
  - "app/views/{sessions,trials,user_mailer}/**"
  - "app/views/dashboard/{_trial_banner,_trial_ended}.html.erb"
  - "app/views/api_keys/{_trial_note,_key_guide}.html.erb"
  - "lib/boot/app_host.rb"
  - "script/mint_invite_code.rb"
  - "railway.toml"
  - "spec/**/*{session,login,trial,invite,preview,app_host}*"
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
- **Account usage table**: `/account` shows this calendar month's own-key
  requests and tokens per provider from `ApiUsage.own_key_totals`, in the
  user's zone. House-key rows stay out, since the account's key did not pay
  for them. Input counts cache reads and writes; no cost is shown.
- **Passwordless sign-in** (`docs/decisions/passwordless-sign-in.md`): the
  emailed code is the only first factor, and no password column is ever
  added. A code request creates the account. Sign-in runs `reset_session`
  before setting `session[:user_id]`, and `require_login` saves the return
  address only for a GET whose `Accept` names `text/html`. There is no second
  factor until the optional authenticator ships. The admin page is
  single-factor until then. The `otp_*` columns are kept but unread.
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
  would give the preview app `default_url_options` and an ActionCable origin
  check pointed at production's host instead of its own. `AppHost` reads that
  variable directly rather than through `PreviewEnvironment`, which is not
  loadable during `Rails.application.configure`; a spec asserts the two names
  agree.
