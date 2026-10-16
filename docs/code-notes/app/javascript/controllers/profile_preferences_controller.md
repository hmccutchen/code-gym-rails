# app/javascript/controllers/profile_preferences_controller.js

## What it owns

Setup's three standalone preference controls: the time zone select, the Daily
sections radio group, and the Track select (`skill_level`). Each one PATCHes
`/profile` on change.

## One key per control, one URL for all of them

Every control sends to the same path, so the save key is what tells them
apart in the save banner. A shared key would let one control's success clear
another's warning, which is why `queueSave` takes the key from the caller
rather than deriving it from the URL.

## Why the skill-level label is rewritten here

Each difficulty fieldset shows "Your track (Junior)" as its
default option. That text names the stored skill level, so changing the level
leaves every one of those labels stale until the page reloads. The controller
rewrites them from `labelTemplateValue`, whose `__LEVEL__` placeholder the
server renders once. It rewrites them only after the save succeeds, so a
refused save never leaves the page claiming a level that was not stored.

The labels are found with a document-wide query rather than a target, because
they are rendered by `api_keys/_difficulty_controls`, which sits inside the
exercise-mix controller's element and so cannot carry this controller's
targets.

## An edit made before the modules load

Time zone, Daily sections and Skill level are server-rendered and nothing is
bound until `connect()`, which waits on the deferred module graph. So
`connect()` compares each control with what the server rendered — the
default-selected option for a select, `defaultChecked` for the sections
radio — and queues the save the missing listener would have sent. Without it
the choice sits on screen unsaved until the user touches the control again.

## A track change hands the Exercise mix the saved state

A track change can clear targets (`TrackChange`) and bump the preference
version, so the Exercise mix's radios and version would otherwise be stale and
its next save refused. The reply carries the same preference state a 409 sends,
and this controller dispatches it, with the reply's `kind_rungs`, as
`profile-preferences:trackSaved` on the document, which the Exercise mix's element listens for. The track save goes on
the mix's queue line (`line: "exercise_mix"`), so it and a mix save never
travel together and the mix never posts the version the track change moved
past. An event rather than a
reach into the other controller keeps each controller's state its own. The
reply's `kept_own_level` sentence, written by the server, fills the status line
under the select; it is empty when no target was kept.
