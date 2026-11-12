# bin/setup

`bin/setup` sets up a development checkout or brings an existing one up to date. Every step is safe to run again, so you can run it at any time: `bundle check` skips the install when the gems are already there, `npm ci` and `lefthook install` replace what they installed before, and `db:prepare` creates the database only when it is missing and otherwise runs pending migrations.

Add a new setup step to the script itself, and keep it safe to repeat.

The Rails generator's version of this script carried a commented-out step that copied `config/database.yml.sample` into place. This repository commits `config/database.yml`, and development needs no environment variables (CLAUDE.md, "Local Development"), so the step was deleted rather than kept as dead code.

The last step starts `bin/dev` with `exec`, which replaces the setup process. Output still in Ruby's buffer at that point would be lost, so the script flushes standard output first. Pass `--skip-server` to stop after setup instead.
