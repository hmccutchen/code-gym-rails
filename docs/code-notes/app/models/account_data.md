# `AccountData`

`FATES` is the one list of what deleting an account does to each table
that refers to a user (`docs/decisions/deleting-an-account.md`). Each entry
has a kind from `KINDS`, the columns through which the table refers to the
person, a one-line reason, and for `:delete` and `:nullify` a `rows` lambda
that returns the person's rows.

The hash order is the deletion order: a row goes before the row its
foreign key points at, so `review_follow_ups` comes before
`daily_responses`, the three tables pointing at `daily_exercises` come
before it, and `users` is last.

`AccountDeletion` acts on the kinds; `spec/conventions/user_data_coverage_spec.rb`
reads `columns` and fails when the schema has a reference with no entry.
`:cascades` and `:keep` entries are there so the coverage spec and a reader
see that the table was considered; deletion does nothing for them.

The file names every table that refers to a user, including the trial,
duck thread and level suggestion tables, so the three isolation specs that
scan for those names list it as one of the files allowed to name them. It
holds data only and reads no one's state.
