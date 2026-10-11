# app/javascript/controllers/profile_preferences_controller.js

## What it owns

Setup's three standalone preference controls: the time zone select, the Daily
sections radio group, and the Skill level select. Each one PATCHes
`/profile` on change.

## One key per control, one URL for all of them

Every control sends to the same path, so the save key is what tells them
apart in the save banner. A shared key would let one control's success clear
another's warning, which is why `queueSave` takes the key from the caller
rather than deriving it from the URL.

## Why the skill-level label is rewritten here

Each difficulty fieldset shows "Follow my skill level (junior)" as its
default option. That text names the stored skill level, so changing the level
leaves every one of those labels stale until the page reloads. The controller
rewrites them from `labelTemplateValue`, whose `__LEVEL__` placeholder the
server renders once. It rewrites them only after the save succeeds, so a
refused save never leaves the page claiming a level that was not stored.

The labels are found with a document-wide query rather than a target, because
they are rendered by `api_keys/_difficulty_controls`, which sits inside the
exercise-mix controller's element and so cannot carry this controller's
targets.
