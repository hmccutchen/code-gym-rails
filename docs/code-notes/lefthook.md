# lefthook.yml

Lefthook runs CI's checks on your machine before a commit or a push reaches GitHub. `bin/setup` installs the hooks with `bundle exec lefthook install`. On a checkout that predates that step, run the same command once.

This note holds the list of what runs; CLAUDE.md and the file map point here rather than repeating it.

## What runs when

**On commit**, only the staged files are checked, so a commit stays fast:

- RuboCop, with `--force-exclusion` so the excludes in `.rubocop.yml` apply to files passed by name. RuboCop would otherwise inspect any file it is handed, a dot-folder's included. RuboCop decides which staged files are Ruby, so the hook carries no file list of its own.
- `bin/comment-check`. `CommentCheck.checked_path?` (`lib/comment_check.rb`) decides which files it reads, for the hook and for CI's full scan alike.

Neither checks `.claude/`. The skills vendored under `.claude/skills/` keep the comments they came with (CLAUDE.md, "Comment rules"). RuboCop skips the folder through `AllCops: Exclude` in `.rubocop.yml`, and comment-check through `CommentCheck::SKIPPED_FOLDERS`.

**On push**, these run in parallel, with the same commands CI uses:

- RuboCop and `bin/comment-check` over the whole repository, which catches offenses a config or house-cop change creates in files the commits didn't touch
- `archspec check`
- Brakeman
- `importmap audit`, which needs the network
- the unit suite (`rspec --exclude-pattern "system/**/*_spec.rb"`), which takes most of the push's time

The system specs stay in CI. They need Playwright's Chromium and take several more minutes, and the unit suite catches most breaks first. CLAUDE.md still asks you to run `spec/system` once before opening a PR.

The unit suite needs Prettier's packages, because `CodeFormat`'s specs run Prettier for real. `bin/setup` installs them with `npm --prefix vendor/prettier ci`, as CI does.

## Skipping and running by hand

- `LEFTHOOK=0 git push` (or `git commit`) skips the hooks for that one command.
- Every worktree shares one set of hooks and one test database. A push while any other spec run on this machine is using that database (another worktree, session or review agent) can fail falsely, so wait for the other run or skip the hook.
- `bundle exec lefthook run pre-push --force` runs the push checks by hand. Lefthook skips a push job when the push carries no changed files: an up-to-date branch, a tag or a deleted branch. `--force` runs it anyway.
