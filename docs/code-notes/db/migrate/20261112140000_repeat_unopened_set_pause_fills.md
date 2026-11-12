# RepeatUnopenedSetPauseFills

`AddUnopenedSetPauseColumns` shipped a release before any code read its three
columns, and filled them for the rows that existed when it ran. Between that
release and this one the app kept writing with code that did not know the
columns:

- an account paused from the Account page got a pause time and no source;
- an account resumed from it kept the `manual` source the first fill wrote;
- a set was created with no `opened_at`, whether or not anyone opened it.

This migration repeats the fills for those rows. Each statement is guarded so
it leaves a recorded value alone: a source already written for a paused
account stays, and so does an `opened_at` already stamped.

Without the `opened_at` fill, every set generated in that gap would read as
unopened, and the first hourly hand-out after the deploy could pause an
account that had been using the app all along.

The `users` statements run before the `daily_exercises` one. That is the order
`PracticeGeneration.commit_new` takes its locks, so the migration and a
generation committing at the same moment cannot deadlock.

`down` does nothing. The code from before this release reads none of the three
columns, so the filled values change nothing for it, and the rows the fills
touched cannot be told apart from rows the app wrote afterwards.

## What it does not cover

Web and worker deploy separately, so for a short time after this migration
runs a process on the previous release can still write. A set it creates has
no `opened_at` and is never stamped by that process's dashboard. One such set
that its owner opened without saving anything counts as unopened. A pause
needs three in a row, so a single miscounted set cannot cause one alone.
The pause columns need no second fill: `User` reads the pause time as the
authority, so a pause with no source reads as manual and a source with no
pause time is ignored (`docs/decisions/pausing-generation.md`).
