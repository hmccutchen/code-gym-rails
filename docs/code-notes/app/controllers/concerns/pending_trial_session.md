# app/controllers/concerns/pending_trial_session.rb

`PendingTrialSession` owns the `:pending_trial` session key, the way `PendingLogin` owns the pending sign-in's keys. `TrialsController#start` writes it with `remember_pending_trial`. `SignInCompletion#complete_sign_in` reads it with `take_pending_trial` before `reset_session` discards it. `SessionsController#create`, and a repeated post that finishes a sign-in, drop it with `forget_pending_trial`. `SignInCompletion` and `TrialsController` include it, so no controller names the key.

The model, `PendingTrial`, never sees the session. It gets plain values: `PendingTrial.dump` builds the hash the session stores, `PendingTrial.load` reads one back, and `#start_for` decides whether the account that entered the code may start the trial. The key and the hash's string keys are the ones the model used before this concern existed, so a pending trial written before a deploy still starts after it.

`take_pending_trial` deletes the key whatever it holds, so a login takes the pending trial once, whether the trial then starts, is refused, or the stored value can't be read.
