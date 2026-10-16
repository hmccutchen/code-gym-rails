# app/controllers/profile_controller.rb

## `#invalid_section_kind_levels?`, `#invalid_display_preferences?`, `#invalid_skill_level?`

These follow the same rule as `#invalid_section_kind_weights?`: a value of the
wrong shape must fail with a 422. Strong params would otherwise drop it, and
the request would return 200 having saved nothing.

## `#saved_body` and `#track_body`

The response includes `section_kind_preferences_version`, `kind_rungs` and the
ladder preparation only when the request touched a preference or the track,
so the body every other caller receives is unchanged. A track change can clear
targets (`TrackChange`), so its reply also carries the saved levels and locks
and `kept_own_level`: Setup hands them to the Exercise mix so its radios and
version match the server without a reload, and names the sections that kept
their own level.

## `TRACK_CHOICE_KEYS` and `#invalid_track_choice?`

The welcome page posts `choose_track: true` with a `skill_level` and nothing
else; any other key refuses the whole request. The level must be one
`LevelSuggestion::LADDER` holds: principal engineer is set by hand in Setup,
never chosen at first run. The choice is checked after the row lock reloads
the user, because a choice bumps no preference version, so only
`User#first_run?` read under the lock stops a second tab from choosing twice.

## `#render_stale_track_page`

A post that carries `learning_track` comes from a page rendered before tracks
per level: the old welcome page, whose junior choice would save presets
without recording a choice, or Setup's old Leave control. It gets a 422 asking
for a reload and saves nothing.

## `level_suggestion_steps`, `moved_since_shown?` and `unsaved_shown_step?`

An Apply from the dashboard card, and a Setup save opened from the card's
link, send the moves the page showed as `level_suggestion_steps`
(`LevelSuggestionStep`). A level suggestion is shown at a kind's rung, which
for a kind without a target is the skill level, and a skill-level change bumps
`section_kind_preferences_version` only when it clears a target. So the version alone cannot tell
that a card is stale. Under the row lock, after the version check,
`moved_since_shown?` compares each step's `from` with the stored rung and
answers 409 when any has moved, saving nothing; the card already reloads on a
409. `unsaved_shown_step?` then refuses, with a 422, a step this request does
not actually save. The checked steps reach `User#shown_level_suggestions`, and
the applied event rows label those moves `suggestion`.

## `locked_save?`

A save takes the user-row lock when it carries a preference version, posted
steps, a track choice, a skill level or targets. The last two matter even
without a version: either can move a kind's rung, and `record_level_changes`
then merges into `level_suggestion_cutoffs`, which the dismissal endpoint
also writes under that lock. Without it, Setup's skill-level select, which
sends no version, could write back a cutoff map read before a Not now
committed and lose that cutoff.

## `#mixed_track_save?`

A post that carries `skill_level` together with any Exercise mix key, outside
the welcome choice, is refused with a 422. `TrackChange` runs on the save, so
it would clear a target the same request had just set when that target equals
the old or the new track. No page sends both: Setup's track select sends the
level alone and the mix sends its keys alone. Refusing the pair keeps the
order of the two from ever deciding what is stored.
