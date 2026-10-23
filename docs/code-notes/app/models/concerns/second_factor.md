# app/models/concerns/second_factor.rb

The optional authenticator app. `docs/optional-totp-spec-2026-10-23.md` has the decisions; this note covers the parts of the code that look odd without them.

## Every write runs under the row lock

Each public method that reads and then writes the second-factor columns runs inside `with_lock`, which reloads the row first. Two submits of the same code then run one after the other, and the second sees the step the first stored. `verify_under_lock` exists so `regenerate_recovery_codes!` and `disable_second_factor!` can verify inside the lock they already hold.

## Telling a TOTP from a recovery code by shape

Input is normalized first: spaces and dashes removed, letters upcased. Ten characters from `RECOVERY_CODE_ALPHABET` are compared against the recovery digests and nothing else. Anything else is checked as a TOTP only. The alphabet has no `0` or `1`, so no 6-digit input can look like a recovery code.

This matters for cost. A bcrypt comparison takes about 0.25 seconds at production cost, and there are up to ten digests. A wrong 6-digit guess would otherwise hold the row lock for about 2.5 seconds.

## Replay and drift

`ROTP::TOTP#verify` gets one step of drift either way and `after: consumed_timestep * 30`, so it refuses any step at or before the last one used. The accepted step is stored as `consumed_timestep`.

## The daily cap

`SECOND_FACTOR_DAILY_FAILURES` wrong codes inside `SECOND_FACTOR_FAILURE_WINDOW` refuse every code, right or wrong, until the window that began at the first failure ends. Successes never count. The count lives on the row so a copied session cookie can't bring back a zero.

## Ending other sessions

`enable_second_factor!` and `disable_second_factor!` set `sessions_valid_after` to the same time they return as `changed_at`. The controller writes that time into the current session, so only the other sessions end (`SignedInSessions`). The time is floored to microseconds so it compares equal to the stored column and to the session stamp.
