# config/database.yml

## test

parallel_tests gives each process its own database by setting
`TEST_ENV_NUMBER`: an empty string for the first process, then 2, 3 and so on.
The suffix goes on `database`. When `DATABASE_URL` is set, the `url` key is
used, and a `url` key here outranks `DATABASE_URL`, so the suffix goes on the
URL too. Without `TEST_ENV_NUMBER`, both forms resolve to the same single test
database.

## production

Railway provides one Postgres database through `DATABASE_URL`. Solid Queue,
Solid Cache and Solid Cable all share it, and a regular migration creates
their tables. So this file must hold exactly one database config for
production: `db:migrate` runs against every configured database, and any
extra logical database would not receive `DATABASE_URL` and would fail to
connect on deploy.

Rails merges the values in `DATABASE_URL` over the ones in this file, so the
password and host never need to be written here.
