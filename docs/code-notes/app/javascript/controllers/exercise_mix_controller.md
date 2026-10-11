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
