# app/views/api_keys/edit.html.erb

## Label minimum height

A tap on an exclude, lock, difficulty or daily-sections label toggles its
box, so the label is the tap target. 24px is the WCAG 2.5.8 minimum for it.

## Fixed and single-kind groups

These groups complement the rotating loop below them: a slot holding one
candidate has nothing to weigh or exclude, but its difficulty can still be
set. The fixed kinds share one group because they share a promise, that they
are in every set. Any other single-kind slot appears in some sets only, so it
gets a group of its own.

## Rotating groups

The rotating groups are derived from the slot roster, as
`ExerciseSection.rotatable` and the `User` validations are. A slot holding one
candidate has nothing to bias, and a future multi-kind slot gets its controls
without an edit here.

## save

`CodeGymSaveStatus` owns the request, the CSRF token, and what happens when
the server refuses (see `shared/_save_status`).

## Daily sections saves

Daily sections saves are chained, like the skill level's, so a slow older
save cannot land last and store a count the page no longer shows.

## Skill level saves

Skill level saves are chained like the Exercise mix's. Sent in parallel, a
slow older request could land last and store a level the page no longer
shows. The Exercise mix's default options name the stored skill level, so
they change only once the server has it.

## syncDifficulty

A lock means something only with a level, so choosing the default clears the
lock in the page rather than posting a lock the server would refuse. Coverage
does not depend on the level, so it shows as soon as a level is chosen.

## lockLastInGroup

A group's last remaining kind cannot be excluded. The server validation is
the authority; this only stops the page offering it.

## version

`version` is the preferences version this tab last saw. Every mix save posts
it, so a tab whose controls predate another tab's save is refused rather than
overwriting it. It is updated from whatever the server reports back. A no-op
save does not bump the server's version.

## applyServerState

After a refusal, this puts the server's state on screen, so the engineer sees
what is stored instead of re-applying a change against a version that can
never match again.

## Chained mix saves

The debounce spaces saves by only 400ms, so a request slower than that is
still in flight when the next is sent. That next request would post the
version the first is about to move, be refused as a conflict with itself, and
snap the user's latest change back. Chaining the tab's own saves prevents it.
