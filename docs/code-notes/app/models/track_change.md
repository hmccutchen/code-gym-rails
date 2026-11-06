# TrackChange

The one statement of what a track change currently does to per-kind targets. A target
equal to the old or the new track level, and not locked, is cleared, so that
kind follows the track again. Every other target stays: one above the new
level was earned, one below the old level stepped back, a locked one was asked
for, and on a two-rung move one between the two levels was earned or chosen.

The rule is stated by level, not by rung distance, because Setup lets a person
move the track more than one rung at a time.

`LevelChange#clear_track_targets` applies it during `ProfileUpdate`'s save,
before `User` runs `bump_section_kind_preferences_version`, so a track change
that clears targets also bumps the preferences version and an open Exercise
mix in another tab gets the usual 409.

Once presets stop being written, a target equal to the old level can't be told
apart from one chosen on purpose, so a deliberate target at the old level is
cleared too. Only a lock protects it. That was decided on 2026-10-15.
The approved replacement in #720 preserves explicit targets and previews a
change before Apply, but is not implemented. Future graduation also needs
protection for easier kinds, including a decision about untargeted kinds;
the current clearing rule does not provide it. See `docs/decisions/tracks.md`
for the distinction between current behavior and these future directions.
