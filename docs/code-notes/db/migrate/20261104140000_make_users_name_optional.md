# db/migrate/20261104140000_make_users_name_optional.rb

`users.name` is read and written by nothing now, and `User` ignores it. The
column was `NOT NULL` with no default, so a release that no longer sends a name
could not insert a user. This migration makes it nullable and nothing else.

It runs before the new web release takes traffic, while the previous release
still serves. That release writes a name on every sign-up and account
deletion, and a nullable column accepts it, so neither request fails during the
deploy. A later release drops the column (#686), once web and worker both run
code that ignores it (`.claude/rules/deployment.md`, "Migrations").

The guard is for a pull-request app whose database already ran an earlier
version of this change that dropped the column outright. There the column is
gone and there is nothing to relax. `down` restores `NOT NULL`, filling any
null with an empty string first.
