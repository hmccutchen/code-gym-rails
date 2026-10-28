# app/forms/profile_update.rb

## Shape here, allowed values in `User`

`PATCH /profile` used to check each field twice: the controller refused a
weight, level, skill level, display option or daily count outside its list,
and `User`'s validators refused the same values again (#434). The form now
checks only the posted shape, which is what the request boundary has to
catch, and leaves which values a field allows to `User`:

- A map field (`section_kind_weights`, `section_kind_levels`,
  `display_preferences`) must be an object, and a list field
  (`excluded_section_kinds`, `locked_section_kinds`) a list of strings.
  Strong params drop a value of the wrong shape, so without this check the
  request would return 200 having saved nothing for that field. A nested
  value inside an object is kept by `permit(key: {})`, so `User` refuses it.
- `skill_level`, `name` and `time_zone` must each be a string or null, for
  the same reason.
- `daily_section_count` must be an Integer, a string of digits or
  `"automatic"`. Active Record's integer cast would read `""` as nil, which
  means Automatic, and `"2.5"` as 2. The range is `User`'s.
- `level_suggestions` must be a JSON boolean, since the cast reads `"yes"` as
  true.
- `daily_section_kinds` must be a list of strings that
  `DailyKinds.problems_with` accepts. A refusal is worded for the person at
  Setup's Daily sections chooser, since a repeated kind or a second fourth is
  a choice they made there. Posting it is a locked save, so a `layout` the
  page posts with it is checked against another tab's swap (as is `places`,
  the whole stored list, which also catches a swap of a place the setting
  hides), and a list equal
  to the default pair stores as empty (`DailyKinds.stored`).
- A `daily_section_count` above the pair's size must come with a
  `daily_section_kinds` list holding a kind for every place. The check reads
  only the request, so a count stored before the chooser existed keeps
  rotating its unchosen places, and a stale tab gets a 422 asking it to
  reload.

The request specs read `User`'s messages for a value outside a list, so
`User` words them for a person, and the form builds its shape messages for
the skill level and the daily count from the same `User::SKILL_LEVEL_RULE`
and `User::DAILY_SECTION_COUNT_RULE` (the `Daily sections` attribute name is
in `config/locales/en.yml`).

A value outside a list is found when `User` validates, which is after the
locked checks. So a tampered post that also carries a stale version gets the
409, and a bad level posted with `choose_track` gets the track-choice 422.
No page sends either.

## `TRACK_CHOICE_KEYS` and `#invalid_track_choice?`

The welcome page posts `choose_track: true` with a `skill_level` and nothing
else; any other key refuses the whole request. The level must be one
`LevelSuggestion::LADDER` holds: principal engineer is set by hand in Setup,
never chosen at first run. The choice is checked after the row lock reloads
the user, because a choice bumps no preference version, so only
`User#first_run?` read under the lock stops a second tab from choosing twice.

## A post carrying `learning_track`

It comes from a page rendered before tracks per level: the old welcome page,
whose junior choice would save presets without recording a choice, or
Setup's old Leave control. It gets a 422 asking for a reload and saves
nothing.

## `level_suggestion_steps`, `#moved_since_shown?` and `#unsaved_shown_step?`

An Apply from the dashboard card, and a Setup save opened from the card's
link, send the moves the page showed as `level_suggestion_steps`
(`LevelSuggestionStep`). A level suggestion is shown at a kind's rung, which
for a kind without a target is the skill level, and a skill-level change bumps
`section_kind_preferences_version` only when it clears a target. So the version alone cannot tell
that a card is stale. Under the row lock, after the version check,
`#moved_since_shown?` compares each step's `from` with the stored rung and
answers stale (409) when any has moved, saving nothing; the card already
reloads on a 409. `#unsaved_shown_step?` then refuses, with a 422, a step
this request does not actually save. The checked steps reach `LevelChange`
as `shown`, and the applied event rows label those moves `suggestion`.

## `#locked_save?`

A save takes the user-row lock when it carries a preference version, posted
steps, a layout, a track choice, a skill level or targets. The skill level
and targets matter even without a version: either can move a kind's rung,
and `LevelChange#record_cutoffs` then merges into `level_suggestion_cutoffs`,
which the dismissal endpoint also writes under that lock. Without it,
Setup's skill-level select, which sends no version, could write back a
cutoff map read before a Not now committed and lose that cutoff.

Any Exercise mix field (`PREFERENCE_KEYS`) takes the lock too, with or
without a version. `SectionKindSettings#keep_unrendered` merges the stored
entries for unrendered controls into the save, and it must read the pair and
those entries from the locked row, not from a copy a swap may have changed.

## `#mixed_track_save?`

A post that carries `skill_level` together with any Exercise mix key, outside
the welcome choice, is refused with a 422. `TrackChange` runs on the save, so
it would clear a target the same request had just set when that target equals
the old or the new track. No page sends both: Setup's track select sends the
level alone and the mix sends its keys alone. Refusing the pair keeps the
order of the two from ever deciding what is stored.

## The rendered layout is checked as well as the version

Which Exercise mix controls a page has depends on the daily pair it was
rendered for, and `SectionKindSettings#keep_unrendered` keeps only what the
current pair hides. A matching version does not prove the page has the right
controls: a track save's reply hands the page the new version without
rebuilding them, so after a swap in another tab the next mix save would pass
the version check and delete a hidden sibling's setting. A save that posts
`layout` is therefore checked under the user lock (`#layout_moved?`), and a
mismatch is stale with `layout_changed: true`, which makes the page reload.
A save that posts no layout, such as the track control's, is not checked.

## `#save_profile`

It assigns the posted fields, validates, and only then calls `LevelChange`
in order, all in one transaction (see
`docs/code-notes/app/models/level_change.md`). The validation comes first
because `LevelChange#record_cutoffs` reads the assigned time zone: a post
carrying an unknown zone and a target change would otherwise raise instead
of answering 422. A failed
validation leaves the user object holding the unsaved values; a request
discards it, but a caller that reuses the object must reload it before the
next save, since `with_lock` refuses a record with unsaved changes.
