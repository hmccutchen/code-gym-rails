# app/controllers/profile_controller.rb

## `#invalid_section_kind_levels?`, `#invalid_display_preferences?`, `#invalid_skill_level?`

These follow the same rule as `#invalid_section_kind_weights?`: a value of the
wrong shape must fail with a 422. Strong params would otherwise drop it, and
the request would return 200 having saved nothing.

## `#saved_body`

The response includes `section_kind_preferences_version` and the ladder
preparation only when the request touched a preference, so the body every
other caller receives is unchanged.

## `LEVEL_SUGGESTION_KEYS`

The suggestions switch saved as `track_suggestions` before the column was renamed `level_suggestions`. A Setup tab opened before the rename still posts the old key, so the controller accepts either, holds both to the same true-or-false check, and saves the old one under the new name. Remove the old key with the ignored track columns.

## `locked_save?` and `stale_expected_rungs?`

A level suggestion is shown at a kind's rung, which for an untargeted kind is the skill level. Changing the skill level does not bump `section_kind_preferences_version`, so the version alone cannot tell a card's Apply that the rung it showed has moved. Apply therefore sends `expected_rungs`, the rung each listed kind was shown at, and the save is refused with the usual 409 when any of them no longer holds; the card's existing stale path reloads. A save that touches `skill_level` or `section_kind_levels` takes the user-row lock even without a version, because both now merge into `level_suggestion_cutoffs`, which the dismissal endpoint also writes under that lock.
