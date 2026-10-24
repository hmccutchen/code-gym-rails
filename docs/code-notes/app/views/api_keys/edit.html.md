# app/views/api_keys/edit.html.erb

## Card order

The page is four cards on `.phone-page`: Connection (the key, the provider
choice, the exercise language and Save key), Your day (time zone, Daily
sections, Track), then the Exercise mix and Display disclosures, which are
`details.card`. The Connection heading carries a "Tap Save to apply" tag
(`.card-heading` and `.card-tag`), because Save key is the one control on the
page that waits for a tap, and the controls below it save by themselves.

## Muted paragraphs: `:where(...) p:not(.card-note)`

The disclosures still hold paragraphs written as bare `<p>` that need the old
muted colour and bottom margin. The page rule that gives them that is
`:where(#exercise-mix, #display-preferences) p:not(.card-note)`. `:where()`
makes the two ids add no weight, so the rule counts as one class (the
`:not()` takes its argument's weight) plus one element: (0,1,1). That is
exactly the weight of the `.setup-wrap p` rule it replaced, and it sits in
the same place in the page style. A `.card-note` paragraph is excluded and is
left to `phone_cards.css`. Because the weight and the position match, every
paragraph the rule matches resolves as it did before the change. That
includes the `.mix-note` shorthand `margin: .5rem 0 1rem`, which gives up its
bottom margin to the rule's 2rem as it always did. A computed-style dump of
both disclosures confirmed it.

## `settings-fields`

Both disclosures used to be `.form-field`, and three page rules (label, text
input, checkbox and radio) were scoped to that class. Moving the disclosures
onto `.card` took `form-field` off them, so each rule is now
`:is(.form-field, .settings-fields) ...`, and both disclosures carry
`settings-fields`. `:is()` takes its argument's highest specificity, which
equals the old class selector's, so every rule keeps the specificity it had
and the disclosures look as they did. The switch row and the switch are
excluded with `:not(:where(...))`, which adds no specificity, so the level
suggestions switch is not styled as a field label or input. Those rules style
this page's fields and only leave the switch alone, so they stay here; the
style guard (`spec/views/own_styles_spec.rb`) reads a class named only inside
`:not()` the same way. This stays until
the later PR that moves the disclosures' fields onto the card styles, when
`settings-fields` goes.

## Partials' styles

Each partial the page renders carries the rules for its own classes:
`api_keys/_key_guide` its spacing, `api_keys/_display_preferences` its
groups and hints, and `api_keys/_difficulty_controls` its fieldset, lock,
coverage line and suggestion outline, once per page (its own note says how).
`.mix-row .kind-about`, which places the
shared `responses/_kind_about` disclosure across a mix row, sits in the
layout beside the other `details.kind-about` rules, since that partial also
renders on the answer form.

Every partial's `<style>` comes after this page's own block, so a moved rule
still wins a tie in specificity it won before: `.mix-difficulty label` and
`.display-group label` over the settings label rule, `.mix-difficulty legend`
over `.mix-group legend`, and `.key-guide > * + *` and `.mix-coverage` over
`.hint`. `spec/system/settings_partial_styles_spec.rb` measures each result.
The key guide shows only to an account with no key and no sets, so the page
snapshot, taken for an account with a key, carries neither the guide nor its
rules.

## Where save feedback appears

- The level suggestions switch and the Account nudges switch say "Saved" on a
  status line under the switch (`save_switch_controller`).
- The time zone, Daily sections, Track, exercise mix and Display controls say
  nothing when a save works. A failure shows in the fixed `#save-status`
  banner.
- Save key, the provider choice and the language redirect with a flash
  notice, because they go through a full form post.

## Saved time zones

The time zone select keeps its existing US choices and appends the saved zone
under its own name when it is absent from that list. `User` already validates
saved zones against Rails, including browser-detected IANA names. Both the
select and its visible value row read the same options, so a saved
`Europe/London` appears as itself rather than "Detect automatically". A blank
saved zone still shows the automatic choice; timezone resolution is unchanged.

## Label minimum height

A tap on an exclude, lock or difficulty label toggles its
box, so the label is the tap target. The exclude label's 24px is in this
page's style, and the lock and difficulty labels' 24px is in
`api_keys/_difficulty_controls`. The Daily sections labels are
`.segment`s, which carry their own 44px height. 24px is the WCAG 2.5.8 minimum for it.

## Daily and single-kind groups

These groups complement the rotating loop below them: a slot holding one
candidate has nothing to weigh or exclude, but its difficulty can still be
set. The user's daily kinds (`DailyKinds.for`) share one group because they
share a promise, that they are in every set. The other groups come from
`ExerciseSection.optional_slots` for that pair, so a daily kind is never
offered a weight or an exclusion. Any other single-kind slot appears in some sets only, so it
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
