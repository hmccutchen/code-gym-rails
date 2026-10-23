# app/controllers/concerns/sign_in_completion.rb

`SessionsController` and `SecondFactorChallengesController` both finish a sign-in, so the steps live here once.

## Finishing a sign-in

`complete_sign_in` takes the pending trial and `return_to` before `start_new_session_for` runs `reset_session`, since the reset discards both. It then sets `session[:user_id]` and `session[:signed_in_at]` (`SignedInSessions`).

## The stamp predates the code check

The session's `signed_in_at` is the time the controller read before checking the code (`checked_at`), not the time the session is written. The code check reads the account under the row lock and then releases it. If the authenticator is turned on or off from another session in that gap, this request acted on the old state, but the change's `sessions_valid_after` is later than `checked_at`, so the new session counts as signed out on its next request. Stamping the write time instead would let an email-only session outlive the authenticator being turned on. `spec/requests/signed_in_sessions_spec.rb` interleaves both changes.

## The pending second factor

When the account has the authenticator on, the address alone reaches `start_second_factor_challenge` from `SessionsController#create`, and an emailed code from the trial form reaches it from `#verify_code`. It does not sign in. It issues a challenge on the user row and stores `session[:pending_second_factor]`, holding the user id and the challenge's issue time.

- The marker only says which challenge this browser holds. The count of wrong codes is on the row (`second_factor_challenge_failures`), so replaying an earlier copy of the cookie can't bring back a zero count.
- The marker sets no `user_id`, so `current_user`, every page and the cable connection treat the browser as signed out until the second step passes.
- The pending emailed-code keys are removed: the code was used, or none was sent.
- `return_to` and a pending trial stay in place for the second step to read.
