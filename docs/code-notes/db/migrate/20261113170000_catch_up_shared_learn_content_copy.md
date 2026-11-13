# CatchUpSharedLearnContentCopy

Step L5 of making Learn content per user
(`docs/decisions/learn-content-per-user.md`, "Order and deploy gates", step 6).
It runs L4's copy again, so every active account that existed when it read
its list of accounts owns a copy of each shared reference and guide before
the L5 code serves.

## Why it runs again

L4's copy ran once, when L4 deployed. An account created after that, while
L4 code was still serving, read the shared rows through the fallback but got
no copy. L5 removes the fallback, so without a second copy that account
would lose text it could see. The migration runs in the web pre-deploy step,
while the L4 code still serving reads the shared rows, so no account goes
without its text before the new web code serves.

The copy reads the list of active accounts once, before its loop. An account
created after that read, while the deploy is still running, gets no copy.
Most such accounts write their own text with their key, but a trial account
cannot (`User#writes_learn_content?`), and trials can still start through
`/trial/start` with an invite code even though the login page hides the
link. The schema step runs the copy once more, before it deletes the shared
rows, so such an account is without its text only between L5 and that step.

The worker is not gated on it. Its pre-deploy waits for a schema, not for
pending migrations, so an L5 worker can run before the copy reaches a user,
make a billed call for a concept the copy was about to supply, and write a
row at version 1 that makes the copy skip it. The cost is extra provider
calls during one deploy. Deploy web first and let the worker follow once the
pre-deploy has succeeded.

## How it calls the copy

It calls `CopySharedLearnContent.copy_to_active_users` from L4's migration
file, so the SQL is the one L4 shipped and is not repeated here. The copy
inserts only where the user has no row yet (`ON CONFLICT DO NOTHING` on the
per-user unique indexes), so an account L4 already copied to, or one that
has written its own rows, gains nothing. It copies one user per transaction
and takes the user's row `FOR SHARE` first, so the lock order with account
deletion is the one L4's code note describes.

It declares `disable_ddl_transaction!`, since `copy_to_active_users` raises
inside an open transaction rather than hold every user's lock until the end.

## `down` does nothing

As with L4, a copied row cannot be told apart from one the user wrote, so
rolling back deletes nothing.
