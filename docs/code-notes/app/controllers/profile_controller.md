# app/controllers/profile_controller.rb

## `#invalid_section_kind_levels?`, `#invalid_display_preferences?`, `#invalid_skill_level?`

These follow the same rule as `#invalid_section_kind_weights?`: a value of the
wrong shape must fail with a 422. Strong params would otherwise drop it, and
the request would return 200 having saved nothing.

## `#saved_body`

The response includes `section_kind_preferences_version` and the ladder
preparation only when the request touched a preference, so the body every
other caller receives is unchanged.
