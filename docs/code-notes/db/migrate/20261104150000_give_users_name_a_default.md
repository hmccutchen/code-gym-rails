# db/migrate/20261104150000_give_users_name_a_default.rb

`users.name` is read and written by nothing now, and `User` ignores it. The
column is `NOT NULL` with no default, so a release that no longer sends a name
could not insert a user. A default fixes that.

The default is a nonblank placeholder, and the column stays required. The
migration runs before the new web release takes traffic, and web and worker
deploy in no fixed order (`.claude/rules/deployment.md`). A worker still on the
previous release validates that a name is present, and its
`UserMailer#login_code` saves the user with `update!`. A user the new web
release created with a null or empty name would fail that validation, and the
sign-in code would never be sent. A nonblank default passes it.

The release still serving also writes a real name on sign-up and account
deletion, which a default accepts. Names already stored are not touched.

A later release drops the column (#686), once web and worker both run code that
ignores it.

Earlier versions of this change touched the column on a pull-request app or a
development database: one dropped it, and one made it nullable. So `up` does
three things depending on what it finds. A missing column is added back with
the default. A nullable column becomes required again, with its nulls filled by
the default. A column that is already required only gains the default. Every
environment ends in the same shape. `down` removes only the default.
