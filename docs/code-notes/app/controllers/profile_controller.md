# app/controllers/profile_controller.rb

## `#invalid_section_kind_levels?`, `#invalid_display_preferences?`, `#invalid_skill_level?`

These follow the same rule as `#invalid_section_kind_weights?`: a value of the
wrong shape must fail with a 422. Strong params would otherwise drop it, and
the request would return 200 having saved nothing.

## `#saved_body`

The response includes `section_kind_preferences_version` and the ladder
preparation only when the request touched a preference, so the body every
other caller receives is unchanged.

## `TRACK_CHOICE_KEYS`

A track choice may carry only the keys listed for it; anything else refuses
the whole request. `none` lists `skill_level` so the welcome page's
Experienced path can save the starting level in the same request as the
choice. The first-run gate (`User#first_run?`) ends as soon as any
`learning_track` is saved, so a second request for the level would never be
asked. The key is optional: Setup's Leave the track still posts `none`
alone. The value goes through `#invalid_skill_level?` like any other skill
level, and principal engineer is not refused here, since Setup already
offers it through this endpoint.

## `LEVEL_SUGGESTION_KEYS`

The "Suggest level changes" switch saved as `track_suggestions` until the
column became `level_suggestions`. `User` now ignores the old column, so
assigning it would raise `ActiveModel::UnknownAttributeError`, a 500. A Setup
tab opened before that deploy still posts the old key, so for one release the
controller accepts either key, holds both to the same true-or-false check, and
saves the old one under the new name. Remove `track_suggestions` from the list
when the ignored track columns are dropped.

## `level_suggestion_steps`, `moved_since_shown?` and `unsaved_shown_step?`

An Apply from the dashboard card, and a Setup save opened from the card's
link, send the moves the page showed as `level_suggestion_steps`
(`LevelSuggestionStep`). A level suggestion is shown at a kind's rung, which
for a kind without a target is the skill level, and a skill-level change does
not bump `section_kind_preferences_version`. So the version alone cannot tell
that a card is stale. Under the row lock, after the version check,
`moved_since_shown?` compares each step's `from` with the stored rung and
answers 409 when any has moved, saving nothing; the card already reloads on a
409. `unsaved_shown_step?` then refuses, with a 422, a step this request does
not actually save. The checked steps reach `User#shown_level_suggestions`, and
the applied event rows label those moves `suggestion`. A posted step forces
the locked path even without a version.
