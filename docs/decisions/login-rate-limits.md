# Login rate limits

Every way in has a guessing bound, set with Rails' `rate_limit`. Each limit
carries an explicit `name:`, without which Rails would key them into one
shared bucket. `LazyCacheStore` exists solely because `rate_limit` binds its
`store:` at class-load time; resolving `Rails.cache` per call keeps
production on Solid Cache and keeps the limits testable against the test
env's `:null_store`.

**Password and authenticator sign-in.** `Users::SessionsController` allows
10 attempts per address and 20 per IP in 15 minutes. The per-address limit
bounds guessing from rotating IPs, which the per-IP one cannot; its cost is
that anyone can lock an address out of signing in for 15 minutes. Both are
declared with `prepend: true`, so they run before Devise allows params
authentication; otherwise rendering the refusal would sign in the posted user
(`docs/decisions/password-and-authenticator-sign-in.md`). An attacker who has
the password still has to guess a 6-digit code, and a used code cannot be
replayed.

**Mail.** Password reset and confirmation emails (`Users::PasswordsController`,
`Users::ConfirmationsController`) are capped at 5 per address and 20 per IP in
15 minutes, so nobody can flood an inbox or the sending domain through them.

**Sign-up and enrollment.** `Users::RegistrationsController` allows 10
sign-ups per IP an hour, which bounds account and mail creation by address
rotation. `TwoFactorSetupsController` and `BackupCodesController` allow 10
attempts per account in 15 minutes.

**The emailed code for accounts from before passwords.** A 6-digit code is a
weak enough secret that the guessing bound is part of the design.
`FirstSignInsController` caps code requests at 5 per address and 20 per IP,
and submissions at 10 per IP, all per `LOGIN_CODE_EXPIRY`, plus submissions
at 10 per address per hour. The per-address submission cap is hourly, with no
daily one, because anyone can start a login for an address and lock it out of
guessing. The daily per-IP cap on code requests is gone: it bounded account
creation, and this path no longer creates accounts.
