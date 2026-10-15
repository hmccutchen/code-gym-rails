# SeedLevelSuggestionCutoffs

Before level suggestions reached every account, cutoffs were recorded only
for junior-track accounts, and a skill-level change was never recorded for
anyone. An account that had moved a kind by hand, perhaps months ago, kept
no trace of it, so its first submitted dashboard after deploy could propose
a move it had already reversed, from results of an earlier stay at that
rung.

This migration gives every account a cutoff for each registered kind at the
rung it reads today: the kind's target when it is one of
`KindDifficulty::LEVELS`, else the skill level, the same rule as
`KindDifficulty#rung_for`. A kind at principal engineer gets none, since no
suggestion leaves that rung. An existing cutoff wins over the seed (the seed
is merged under it), so a track account's recorded dismissals keep their
dates.

The date is the migration's UTC date, not each user's local date: the zone
names `users.time_zone` holds are Rails names Postgres does not read. The
difference is at most a day of results at the seeded rung either way.

The cost is deliberate: no account gets a card until it has five reviewed
results at its rung after deploy (two of three too-hard results for a step
back). The migration reads `ExerciseSection.keys` and the level lists at the
time it runs. `down` does nothing, because a seeded entry looks like any
recorded cutoff, and the column migration's own `down` removes the column.
