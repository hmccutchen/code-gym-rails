# `GenerateRecognitionGuideJob`

## Whose row it writes

The job writes only the user's own row (`docs/decisions/learn-content-per-user.md`).
It skips the call when the user already has their own guide for the group,
because a guide is never rewritten. Another user's guide does not count.
Every guide has an owner, so the job writes no shared row. A trial account writes nothing (`User#writes_learn_content?`),
and neither does an anonymized one, which `User.active` leaves out.

## Concurrency

The permit is keyed on user and group key, with `on_conflict: :discard`.
A second job for the same user and group would bill a second call for a row
the first one writes, so it is dropped. Another user's job writes another
row, so it has its own permit and is never discarded by this one. When the
permit is bypassed (an expired permit, a direct `perform_now`), the unique
index on user and group key catches the second insert, and the job logs a
skip.

It keeps the discard and takes no claim, unlike `GenerateConceptReferenceJob`.
Only Learn's bulk press queues a guide, at `JobPriority::BACKGROUND`, so no
click ever waits behind a queued guide.

## An account deleted during the call

The provider call runs outside any lock. The save is
`RecognitionGuide.write_for` (issue #790), which share-locks the user row
before it inserts, the lock `AccountDeletion` takes for update. If deletion
committed first, the user is gone and the job writes nothing, so the insert
never fails on the foreign key. If the write committed first, deletion waits
for it and then deletes the new row with the rest of the account. Either way
the job finishes cleanly and leaves no failed execution naming the user.
