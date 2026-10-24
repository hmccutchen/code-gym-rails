# app/models/user/authenticator.rb

The optional authenticator app, as a plain object around one `User` (`user.authenticator`). The columns stay on `users`; `User` keeps `encrypts :otp_secret` and one-line delegates for the calls controllers and views make, under their older names (`enable_second_factor!` calls `enable!`). `docs/decisions/passwordless-sign-in.md` has the decisions; this note covers the parts of the code that look odd without them.

## Every write runs under the row lock

Each public method that reads and then writes the second-factor columns runs inside `user.with_lock`, which reloads that same `User` instance first, so the object always reads what the lock read. Two submits of the same code then run one after the other, and the second sees the step the first stored. `verify_under_lock` exists so `regenerate_recovery_codes!` and `disable!` can verify inside the lock they already hold.

The ten recovery-code digests are built before the lock is taken, since nothing in them depends on the row. At production cost they take about two seconds, and the login code check waits on the same row lock. `enable!` checks the code against the given secret first and builds digests only when it matches, so a wrong setup code costs no bcrypt work. `regenerate_recovery_codes!` can't tell beforehand whether a recovery-shaped code is right, so it builds them on every call; the change rate limit and the daily cap bound that.

## Telling a TOTP from a recovery code by shape

Input is normalized first: spaces and dashes removed, letters upcased. Ten characters from `RECOVERY_CODE_ALPHABET` are compared against the recovery digests and nothing else. Anything else is checked as a TOTP only. The alphabet has no `0` or `1`, so no 6-digit input can look like a recovery code.

This matters for cost. A bcrypt comparison takes about 0.25 seconds at production cost, and there are up to ten digests. A wrong 6-digit guess would otherwise hold the row lock for about 2.5 seconds.

## Replay and drift

`ROTP::TOTP#verify` gets one step of drift either way and `after: consumed_timestep * 30`, so it refuses any step at or before the last one used. The accepted step is stored as `consumed_timestep`.

## The daily cap

`DAILY_FAILURES` wrong codes inside `FAILURE_WINDOW` refuse every code, right or wrong, until the window that began at the first failure ends. Successes never count. The count lives on the row so a copied session cookie can't bring back a zero.

## The sign-in challenge

`issue_challenge!` stamps `second_factor_challenge_at` and zeroes `second_factor_challenge_failures`, unless the open challenge is under `DOUBLE_TAP_WINDOW` old. Then it returns that challenge's time and keeps its count. A double tap's two posts both carry the cookie from before either, so issuing twice would leave the browser holding whichever response arrived last, which may name the challenge that lost. Keeping the count also means re-sending the address can't reset it. `answer_challenge!` checks, under the same lock as the code check, that the browser's marker names that exact time and that it is under `CHALLENGE_LIFETIME` old. A right code, the fifth wrong code (`CHALLENGE_FAILURES`) or the daily cap clears the challenge, so every copy of the cookie stops working at once.

## Ending other sessions

`enable!` and `disable!` set `sessions_valid_after` to the same time they return as `changed_at`. The controller writes that time into the current session, so only the other sessions end (`SignedInSessions`). The time is floored to microseconds so it compares equal to the stored column and to the session stamp.

## Account deletion

`ERASED_ON_ACCOUNT_DELETION` holds every column this class owns with a new account's value, and `User#anonymize!` spreads it into its one locked update. It is wider than what `disable!` clears: turning the authenticator off keeps the challenge and the daily cap's count, and only the cap's own window ends that count (decision 8 in `docs/decisions/passwordless-sign-in.md`). An anonymized account never signs in again, since every sign-in lookup is scoped to `User.active`. A spec fails when this file starts reading or writing a `users` column the hash leaves out, other than `email` and `sessions_valid_after`, and another when a `users` column with a second-factor prefix (`otp_`, `two_factor_`, `second_factor_`, `consumed_`) is missing from it.
