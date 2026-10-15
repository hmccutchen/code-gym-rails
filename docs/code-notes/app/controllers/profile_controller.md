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
