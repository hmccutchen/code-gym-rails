# Skill level control

the choices are the difficulty levels themselves
(`User::SKILL_LEVELS` is `KindDifficulty::LEVELS`), labelled Junior,
Mid-level, Senior and Principal engineer. Junior covers early-career
developers and career changers. They replaced
beginner, developing, solid and strong, which shared their words with the
review grades: a "developing" grade on a review is the grader's word for
where an answer sits, and is no longer also a setting. `AddMidLevelRung`
rewrote any stored legacy value (beginner and developing as junior, solid as
senior, strong as principal engineer) and moved the column default from
`developing` to `junior` before the backfill. An old Rails process could
still insert a cached `developing` default after the migration committed,
which the migration spec reproduces, so `User#skill_level` translated legacy
values on read for a while. A production check on 2026-10-14 found only
current values, with every old process long stopped, so that reader is gone
and a stored value must be one of the levels. A
legacy value posted to `PATCH /profile` is refused like any other value
outside the list.
Setup's "Track" select and the welcome page's choice are the two pages that
edit `User#skill_level` (see `tracks.md`). Setup's autosaves through
`PATCH /profile`, and the welcome choice saves through it too. That
endpoint refuses a value outside `User::SKILL_LEVELS` with a 422. It sets the
profile's prompt line and the rung of every kind without its own target
(`KindDifficulty#rung_for`); scenario settings do not depend on it. Nothing
changes it automatically, and daily ratings still nudge each set around it.
A level suggestion's Apply adds a target instead, so the setting stays where
the user put it, which Setup's hint says. A change clears the targets
`TrackChange` says the track now covers, and records a suggestion cutoff and
a `skill_level_edit` event row for every kind it moves, under the user-row
lock. It is not part of the Exercise mix, so it bumps
`section_kind_preferences_version` only when it clears a target. The Exercise
mix's default options name the stored level by its label ("Your track
(…)") and are renamed in place once a save lands.
