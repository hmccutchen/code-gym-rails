# app/javascript/controllers/exercise_mix_controller.js

## What it owns

Setup's Exercise mix: the per-kind weight sliders, the exclude checkboxes, the
difficulty radios, the locks, and the ladder-preparation button that sits
under them.

## One payload, one version, one queue

Every edit posts the whole mix, including
`section_kind_preferences_version`. Two saves in flight would both post the
version the first is about to move, and the second would 409 against its own
predecessor. `saveStatus.queue` with a single key is what prevents that: the
queue sends one at a time and reads each body when it is sent, so the second
save picks up the version the first stored.

A 409 means another tab moved the version. The reply carries the server's
whole current state, and `applyServerState` writes it back onto the controls
rather than reloading, so an edit in progress is not thrown away.

## The 400 ms delay, and why the prepare button waits on it

A slider fires `input` on every pixel. The delay collapses a drag into one
save. The ladder-preparation button is disabled from the first edit until the
latest save has landed, because it bills a provider call against whatever the
server has stored — pressing it mid-drag would prepare ladders for levels the
user has already moved past.

`editRevision` is what distinguishes "the save that landed is the latest one"
from "a later edit has already been queued", and only the former re-enables
the button.

## aria-valuetext

Without it a screen reader announces the slider's index (`3 of 6`) rather
than the stop word the sighted user sees. The server renders it and
`showStop` keeps it in step.

## Last kind in a rotating group

A slot whose eligible kinds are all excluded has nothing to schedule, so the
last unexcluded checkbox in each rotating group is disabled and the group's
note is unhidden. The server validates this too; the client rule exists so
the user never posts a refused state.

## An edit made before the modules load

The controls here are server-rendered and the controller binds nothing until
`connect()`, which waits on the deferred module graph. `code_gym_bootstrap`
records that an edit happened so `pending()` is honest, but only the controller
can act on it, so `connect()` asks `editedBeforeConnect()` whether any input
differs from what the server rendered — `value` against `defaultValue` for a
range, `checked` against `defaultChecked` for a box or radio.

When one does, `adoptEarlyEdit()` runs the work the missing listeners would
have done — the slider's `aria-valuetext` and output label, the slider's
disabled state, each difficulty group's enablement and the last-in-group lock —
and then saves. Without it the change sits unsaved until the user touches a
control again.

## A suggestion followed into Setup

When Setup was opened from a level suggestion card's link, the server renders
each highlighted kind's step (`suggested`: the rung it is at and the rung
offered). When the user picks the offered level for that kind, the next save
carries the step as `level_suggestion_steps`, so the server can label the
change `suggestion` after checking its `from` against the stored rung.

Once a save is confirmed, a step is kept only while the kind's rung, as the
save's reply reports it (`kind_rungs`), still equals the step's `from`. The
reply carries the rungs so the page never restates the rule that a kind
without a target follows the skill level. Choosing the suggested level, or
any other level that moves the rung, drops the step, since resending the old
`from` would get a 409 and undo the user's valid edit. A choice that keeps
the rung, such as setting Junior explicitly on a kind that already followed
a junior skill level, keeps the step, so a later pick of the suggested level
is still labelled `suggestion`. A 409 clears every step, since the page they
were rendered for is out of date.

## Early edits are read from the mix's own controls

`editedBeforeConnect` scans only inputs inside row and difficulty targets.
The "Suggest level changes" switch sits inside the mix's `<details>` but has
its own controller, and flipping it before the modules load must not start a
mix save.

## A track change saved elsewhere on the page

`adoptTrackChange` takes the preference state Setup's track select received
and applies it with `applyServerState`, the method a 409 already uses, so a
cleared target shows "Your track (…)" and the version matches the server
without a reload. An edit made in the mix less than 400 ms before the track
select's reply arrives is replaced by the server's state, and the delayed save
then sends that state, so the edit is lost and the page shows what is stored.
That takes two edits in under half a second across two controls, and was
accepted rather than merged.
