---
paths:
  - "app/controllers/{first_sign_ins,password_setups,two_factor_setups,trials,accounts,application}_controller.rb"
  - "app/controllers/users/**"
  - "app/controllers/concerns/preview_auto_login.rb"
  - "app/channels/application_cable/connection.rb"
  - "app/helpers/two_factor_setups_helper.rb"
  - "app/models/{invite_code,pending_trial,provider_credential,trial_allowance,trial_mode,trial_status,house_keys,user}.rb"
  - "app/models/concerns/sign_in_credentials.rb"
  - "config/initializers/devise.rb"
  - "app/services/{preview_environment,preview_seed,preview_mail,lazy_cache_store}.rb"
  - "app/views/{first_sign_ins,password_setups,two_factor_setups,devise,trials,user_mailer}/**"
  - "app/views/shared/_auth_page_styles.html.erb"
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
  seat in one statement, and the seat is taken only when a confirmed account
  with the trial's address signs in. `ProviderCredential.for` picks the key, `TrialAllowance.check!`
  runs before every house-key call, and generation, judges and mastery code
  never read trial state (`trial_isolation_spec`); trial branches render only
  for `User#on_trial?`. Trials are paused: the login page carries no trial
  link, while the routes and gates stay in place.
- **Account usage table**: `/account` shows this calendar month's own-key
  requests and tokens per provider from `ApiUsage.own_key_totals`, in the
  user's zone. House-key rows stay out, since the account's key did not pay
  for them. Input counts cache reads and writes; no cost is shown.
- **Password and authenticator sign-in**
  (`docs/decisions/password-and-authenticator-sign-in.md`): Devise with
  `devise-two-factor`: a password plus a TOTP code or a single-use backup
  code, checked together by the gem's strategies on Devise's own
  `sessions#create`, with one message for every failure. Sign-up needs email
  confirmation, but only for accounts created through sign-up
  (`SignInCredentials::DeviseOverrides#confirmation_required?`). A password
  reset never signs in. `ApplicationController` sends a signed-in account
  with no password, then one with no authenticator, to set them up before
  anything else. Never call `current_user` in `Users::SessionsController`
  before params authentication is allowed: the rate limits are prepended
  for that reason, and the stale-token handler reads
  `warden.authenticated?(:user)`.
- **The emailed code for accounts from before passwords**: Only accounts
  in `User.awaiting_password` (no password, not anonymized) can get one,
  from `FirstSignInsController`, which creates no accounts and gives the
  same reply for any address. `User#generate_login_code!` stores a BCrypt
  digest and `User.authenticate_login_code` checks against it. Codes expire
  in 15 minutes (`User::LOGIN_CODE_EXPIRY`), die after five wrong guesses
  (`LOGIN_CODE_MAX_ATTEMPTS`), and work only in the browser that asked,
  since `#verify_code` reads the address from the session. A follow-up PR
  deletes this path once every account has enrolled.
- **Login rate limits** (`docs/decisions/login-rate-limits.md`): sign-in
  attempts per address and per IP, sign-ups per IP, enrollment attempts per
  account, and the emailed-code limits per address and per IP. Each limit
  needs its own `name:`, and `LazyCacheStore` resolves `Rails.cache` per
  call.
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
