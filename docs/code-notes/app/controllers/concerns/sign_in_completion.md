# app/controllers/concerns/sign_in_completion.rb

`SessionsController` and `SecondFactorChallengesController` both finish a sign-in, so the steps live here once.

## Finishing a sign-in

Every caller names the factor that passed: `:emailed_code` from `SessionsController#verify_code`, `:authenticator` from the second step. `complete_sign_in` raises `WrongFactor` unless the factor is the account's own (`User#sign_in_factor`), so it refuses the emailed code for an account with the authenticator on, and any other factor. The controllers already route such an account to the authenticator step; this is the check that holds if a later sign-in path forgets to. Nothing rescues it, on purpose: a fired guard is a programming error, and a 500 is the right answer to it.

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

`remember_sign_in` keeps, for `REPEAT_WINDOW`, an HMAC of what the first post proved: for the emailed code, the address, this browser's `pending_login_at` and the code; for the authenticator step, the user id, the challenge's issue time and the random `browser` value from this browser's marker, and the code. The random value matters because two browsers that send the address within `User::DOUBLE_TAP_WINDOW` share one challenge time, so the time alone would let one browser reuse the other's accepted code. `recent_sign_in` accepts a later post carrying exactly that proof, and the repeat takes the same branch the first post did, so a repeated emailed code for an authenticator account still goes to the authenticator step. A repeat that finishes the sign-in drops a pending trial, since the first post already started or refused it. A repeat that still needs the authenticator step keeps it, because the trial starts only once that step passes.

These details keep the repeat from doing more than the first post did:

- **The proof is written inside the row lock** that redeems the code. `User.authenticate_login_code` and `SecondFactor#answer_second_factor_challenge!` yield inside `with_lock` on success, and the controller records the proof in that block. A duplicate waiting on the lock therefore finds the proof once it gets in. Written after the lock, it could look in between and miss it. The second step also checks for a repeat when the locked answer comes back `:expired`, since two overlapping posts can both pass the open-challenge check before either answers.
- **The repeat keeps the first post's check time.** The proof stores `checked_at`, and the repeat is refused if `sessions_valid_after` has passed it (`User#session_signed_in_valid?`). Otherwise the repeat signs in with that same time. A session ended by turning the authenticator on or off in the meantime stays ended, rather than coming back with a later stamp.
- **Both posts share one authenticator challenge.** For an authenticator account, the challenge is issued inside the redemption's lock and its time goes into the proof. A repeat reuses that time for its marker, never issuing its own, so whichever response the browser keeps names the challenge that is open. A double tap on the address form gets the same result from the model: `User#issue_second_factor_challenge!` hands back a challenge under `User::DOUBLE_TAP_WINDOW` old instead of issuing another.
- **Each sign-in keeps its own entry.** The cache key holds the proof's HMAC, so another browser signing in to the same account within the window doesn't overwrite this browser's proof.
- **The repeat shows the first post's notice.** The proof stores the notice the first post set, such as how many recovery codes are left, so whichever response the browser keeps says the same thing.
- **Replays count against the rate limits.** `SecondFactorChallengesController` declares its rate limits before `require_open_challenge`, so a replayed code is counted even when the challenge is already closed and the proof doesn't match.
- **The emailed-code repeat reads the session's address directly (`pending_login_address`),** not `pending_login_email`. The first post clears the code's `login_code_sent_at`, which can end a late-mailed sign-in's pending life, and the duplicate still has to find its proof. `SessionsController`'s per-address limit is keyed on that same address for the same reason. Keyed on `pending_login_email`, it would fall back to the IP once the pending life ended, and replays from rotating IPs would escape the account's cap.

Nothing new is reachable. Only this browser holds its pending stamp, which is written to the microsecond with `User.session_stamp`, and the code has to match too; anyone with both could have used the code first. The proof lives in the cache. If it's evicted, the repeat is refused as before.
