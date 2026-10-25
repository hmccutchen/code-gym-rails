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
equals the old class selector's, so every rule keeps the specificity it had.
Four things are excluded from the label and input rules:

- The switch row and the switch, each in a `:not(:where(...))` that adds no
  specificity, so the level suggestions switch is not styled as a field label
  or input.
- `.mix-level` and the radios inside it, the same way, so a difficulty row
  keeps the layout `_difficulty_controls` gives it instead of the block label
  and the auto-width radio margin.
- `[type="range"]`, as a third entry in the attribute list of the input
  rules' `:not([type="checkbox"], [type="radio"], [type="range"])`, so the
  slider takes its size from `phone_cards.css` instead of the text-input box
  (full width, padding, border, monospace).

Each class exclusion has its own `:not(:where(...))` because the style guard
(`spec/views/own_styles_spec.rb`) splits a selector at every comma, so a list
inside one `:not()` would read as two selectors. It treats a class named only
inside `:not()` as left alone, not styled.

The class stays after the exclusions. The label rule still styles Display's
option labels, and the text-input rule still styles every other input in the
disclosures, so removing `settings-fields` would change them. It goes only
when those fields move onto the card styles.

## Notes and groups

A note under a control is `.card-note`, which `phone_cards.css` owns. The old
page-wide `.hint` rule is now `:where(.phone-page .mix-note) .hint`, so only
the guide text inside a `.mix-note` keeps that size and colour. `:where()`
keeps the rule at one class of weight, so `.key-guide > * + *` still sets the
guide's spacing. The rule lives in the layout's style, beside the
`details.kind-about` rules, and not in this page's style: the trial note and
the key guide carry `.hint` and are separate partials, only one of which
renders at a time, and the own-styles guard refuses a class the page's own
markup lacks. A copy in each partial would repeat the rule. Every other note takes its look from `.card-note`
and sets only its spacing, so two rules no longer give the same muted text.

A `.mix-group` is a fieldset with no box. Boxes inside a card made every kind
look like a card of its own, with three borders and two paddings between the
card edge and a control, which cost width at 320px. A divider above each group
after the first (`.mix-group + .mix-group`) separates the groups instead.
`min-width: 0` overrides the browser's default fieldset width, which would
otherwise stop a long label from wrapping.

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

## Tap target sizes

The control a finger lands on is the label or the control itself, so each has
a minimum height. The rules sit with the markup that needs them:

- Difficulty options are `label.mix-level` rows, at least 48px tall, in
  `api_keys/_difficulty_controls`.
- The skip and lock switches are `.switch-row`s, at least 48px, in
  `phone_cards.css`.
- The weight slider is 44px tall with a 28px thumb, in `phone_cards.css`.
- An About summary is 44px, in the layout's style
  (`#exercise-mix .kind-about > summary`), beside the other `kind-about`
  rules, because neither the page nor the difficulty partial carries that
  class.
- Display's option labels are 44px, in `api_keys/_display_preferences`.
- The Daily sections labels are `.segment`s, which carry their own 44px height.

48px is the size the other cards use for a row. The spec chose 44px for the
slider and the About summary, so they stay shorter than a switch row; 44px is
still above the WCAG 2.5.8 minimum of 24px.

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
