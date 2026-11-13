# `GenerateConceptReferenceJob`

## Whose row it writes

The job writes only the user's own row (`docs/decisions/learn-content-per-user.md`).
It skips the call when the reference the user sees, their own or the shared
one, is fully written, or when it exists and this is not a refresh. A user
who sees only the shared row and asks for a rewrite gets a new row of their
own. Its `generation_version` starts one past the shared row's, because the
Learn poll compares against the version the page showed and would otherwise
never see the rewrite land. The shared row is never written.

## Concurrency

The permit is keyed on user, language and concept, with `on_conflict:
:discard`. One user's refresh modes share it because they write the same
row. Another user's job writes another row, so it has its own permit and is
never discarded by this one.

## An account deleted during the call

The provider call runs outside any lock. Before writing, the job share-locks
the user row, the lock `AccountDeletion` takes for update. If deletion
committed first, the user is gone and the job writes nothing, so the insert
never fails on the foreign key. If the write committed first, deletion waits
for it and then deletes the new row with the rest of the account. Either way
the job finishes cleanly and leaves no failed execution naming the user.

## `.queue_missing`

The one way write-ups are queued for a set's concepts: on submit, at click
priority, and when a set is generated or regenerated, at bulk priority. It
queues nothing for a trial account (`User#writes_learn_content?`), and
nothing for a pair the user already sees a reference for.
