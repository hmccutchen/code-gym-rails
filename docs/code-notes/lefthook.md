# lefthook.yml

Lefthook runs most of CI's checks on your machine before a commit or a push reaches GitHub. `bin/setup` installs the hooks with `bundle exec lefthook install`. On a checkout that predates that step, run the same command once.

## What runs when

**On commit**, only the staged files are checked, so a commit takes seconds:

- RuboCop on staged Ruby files (`*.rb`, `*.rake`, `*.ru`, `Gemfile`, `Rakefile`). `--force-exclusion` applies `.rubocop.yml`'s excludes to files passed by name, which RuboCop would otherwise inspect.
- `bin/comment-check` on staged ERB, JavaScript, CSS, YAML and Python files.

Both skip `.claude/`, `vendor/` and `node_modules/`. CI's RuboCop never looks in a dot-folder, and the skills vendored under `.claude/skills/` keep the comments they came with (CLAUDE.md, "Comment rules"). Passed by name, those files would be checked anyway, so the hook excludes them itself.

**On push**, these run in parallel:

- `archspec check`
- Brakeman
- `importmap audit`, which needs the network
- the unit suite (`rspec --exclude-pattern "system/**/*_spec.rb"`), about two and a half minutes

The system specs stay in CI. They need Playwright's Chromium and take several more minutes, and the unit suite catches most breaks first. CLAUDE.md still asks you to run `spec/system` once before opening a PR.

## Skipping and running by hand

- `LEFTHOOK=0 git push` (or `git commit`) skips the hooks for that one command.
- Don't push while a review agent is running specs. The push runs the unit suite against the same test database, and two runs sharing it fail falsely.
- `bundle exec lefthook run pre-push --force` runs the push checks by hand. Without `--force`, lefthook skips each push job when nothing is waiting to be pushed.
