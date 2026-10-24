# app/controllers/concerns/sign_in_completion.rb

`SessionsController` and `SecondFactorChallengesController` both finish a sign-in, so the steps live here once.

## Finishing a sign-in

Every caller names the factor that passed: `:emailed_code` from `SessionsController#verify_code`, `:authenticator` from the second step. `finishes_sign_in?` refuses the emailed code for an account with the authenticator on (`User#emailed_code_signs_in?`), and any other factor, by raising `WrongFactor`. The controllers already route such an account to the authenticator step; this is the check that holds if a later sign-in path forgets to.

`complete_sign_in` takes the pending trial and `return_to` before `start_new_session_for` runs `reset_session`, since the reset discards both. It then sets `session[:user_id]` and `session[:signed_in_at]` (`SignedInSessions`).

## The stamp predates the code check

The session's `signed_in_at` is the time the controller read before checking the code (`checked_at`), not the time the session is written. The code check reads the account under the row lock and then releases it. If the authenticator is turned on or off from another session in that gap, this request acted on the old state, but the change's `sessions_valid_after` is later than `checked_at`, so the new session counts as signed out on its next request. Stamping the write time instead would let an email-only session outlive the authenticator being turned on. `spec/requests/signed_in_sessions_spec.rb` interleaves both changes.

## The pending second factor

When the account has the authenticator on, the address alone reaches `start_second_factor_challenge` from `SessionsController#create`, and an emailed code from the trial form reaches it from `#verify_code`. It does not sign in. It issues a challenge on the user row and stores `session[:pending_second_factor]`, holding the user id and the challenge's issue time.

- The marker only says which challenge this browser holds. The count of wrong codes is on the row (`second_factor_challenge_failures`), so replaying an earlier copy of the cookie can't bring back a zero count.
- The marker sets no `user_id`, so `current_user`, every page and the cable connection treat the browser as signed out until the second step passes.
- The pending emailed-code keys are removed (`PendingLogin#forget_pending_login`): the code was used, or none was sent.
- `return_to` and a pending trial stay in place for the second step to read.

## A repeated sign-in post

A double tap that lands before the page's scripts connect posts the same form twice, and both posts carry the cookie from before the first one answered. The first signs in; the second finds the code already spent. The browser shows the second response, so a good code read as wrong.

`remember_sign_in` keeps, for `REPEAT_WINDOW`, an HMAC of what the first post proved: for the emailed code, the address, this browser's `pending_login_at` and the code; for the authenticator step, the user id, the challenge's issue time from this browser's marker, and the code. `recent_sign_in_checked_at` accepts a later post carrying exactly that proof, and the repeat takes the same branch the first post did, so a repeated emailed code for an authenticator account still goes to the authenticator step. A pending trial is dropped on a repeat, since the first post already started or refused it.

Three details keep the repeat from doing more than the first post did:

- **The proof is written inside the row lock** that redeems the code. `User.authenticate_login_code` and `SecondFactor#answer_second_factor_challenge!` yield inside `with_lock` on success, and the controller records the proof in that block. A duplicate waiting on the lock therefore finds the proof once it gets in. Written after the lock, it could look in between and miss it. The second step also checks for a repeat when the locked answer comes back `:expired`, since two overlapping posts can both pass the open-challenge check before either answers.
- **The repeat keeps the first post's check time.** The proof stores `checked_at`, and the repeat is refused if `sessions_valid_after` has passed it (`User#session_signed_in_valid?`). Otherwise the repeat signs in with that same time. A session ended by turning the authenticator on or off in the meantime stays ended, rather than coming back with a later stamp.
- **The emailed-code repeat reads the session's address directly,** not `pending_login_email`. The first post clears the code's `login_code_sent_at`, which can end a late-mailed sign-in's pending life, and the duplicate still has to find its proof.

Nothing new is reachable. Only this browser holds its pending stamp, which is written to the microsecond with `User.session_stamp`, and the code has to match too; anyone with both could have used the code first. The proof lives in the cache. If it's evicted, the repeat is refused as before.
