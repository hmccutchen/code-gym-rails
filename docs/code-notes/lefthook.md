# lefthook.yml

Lefthook runs local static checks before a commit or a push reaches GitHub. `bin/setup` installs the hooks with `bundle exec lefthook install`. On a checkout that predates that step, run the same command once.

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

Neither hook runs RSpec. Full unit and system suites run in CI on the final
PR commit, avoiding a duplicate full local run on each push. CLAUDE.md's
Tests and Git Workflow sections define focused local validation, independent
reviews, and the final CI and GitHub-review merge gates.

## Skipping and running by hand

- `LEFTHOOK=0 git push` (or `git commit`) skips the hooks for that one command.
- Every worktree shares one set of hooks and one test database. Separate local RSpec runs still need exclusive use of that database; the push hook no longer starts one.
- `bundle exec lefthook run pre-push --force` runs the push checks by hand. Lefthook skips a push job when the push carries no changed files: an up-to-date branch, a tag or a deleted branch. `--force` runs it anyway.
