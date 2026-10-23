# app/controllers/concerns/sign_in_completion.rb

`SessionsController` and `SecondFactorChallengesController` both finish a sign-in, so the steps live here once.

## Finishing a sign-in

`complete_sign_in` takes the pending trial and `return_to` before `start_new_session_for` runs `reset_session`, since the reset discards both. It then sets `session[:user_id]` and `session[:signed_in_at]` (`SignedInSessions`).

## The pending second factor

When the emailed code is right and the account has the authenticator on, `start_second_factor_challenge` does not sign in. It issues a challenge on the user row and stores `session[:pending_second_factor]`, holding the user id and the challenge's issue time.

- The marker only says which challenge this browser holds. The count of wrong codes is on the row (`second_factor_challenge_failures`), so replaying an earlier copy of the cookie can't bring back a zero count.
- The marker sets no `user_id`, so `current_user`, every page and the cable connection treat the browser as signed out until the second step passes.
- The pending emailed-code keys are removed, because that code has been used.
- `return_to` and a pending trial stay in place for the second step to read.
