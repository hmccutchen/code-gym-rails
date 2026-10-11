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

## Where the behavior lives

This page carries no script. Its controls are wired by three Stimulus
controllers, each with a note of its own:

- `profile_preferences_controller` — the time zone, Daily sections and Skill
  level controls, and the skill-level labels inside the difficulty fieldsets.
- `exercise_mix_controller` — the sliders, exclusions, difficulty radios,
  locks, the preferences version and the ladder-preparation button.
- `display_preferences_controller` — the Display disclosure, rendered by
  `api_keys/_display_preferences`.

The exercise-mix controller's element is the `#exercise-mix` disclosure, so
`api_keys/_difficulty_controls` carries that controller's targets and actions
even though it is also rendered for the fixed and single-kind groups.
