# `AccountDeletion`

Deletes an account and every row that belongs to it, in one transaction,
following `AccountData::FATES`
(`docs/decisions/deleting-an-account.md`). It returns an `Outcome` whose
status is one of `STATUSES`: `:deleted`, or `:already_deleted` when another
request deleted the account first. `AccountsController#destroy` signs the
browser out and shows the same message for both.

The locks follow the order in `.claude/rules/patterns.md`: the user row,
then the exercises, responses and mastery rows (`LOCK_ORDER`), each in
ascending id order. Holding the user row's `FOR UPDATE` blocks every insert
into a table with a foreign key to `users`, and holding the responses blocks
a follow-up insert, so nothing is added for the person between the locks
and the deletes.

The GlobalIDs of the user, their exercises and their responses are read
before anything is deleted, so `UnfinishedJobs` can match a mailer job that
names a response.
