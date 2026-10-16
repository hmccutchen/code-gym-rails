# app/javascript/controllers/exercise_mix_controller.js

## What it owns

Setup's Exercise mix: the per-kind weight sliders, the exclude checkboxes, the
difficulty radios, the locks, and the ladder-preparation button that sits
under them.

## One payload, one version, one queue

Every edit posts the whole mix, including
`section_kind_preferences_version`. Two saves in flight would both post the
version the first is about to move, and the second would 409 against its own
predecessor. `saveStatus.queue` on the `exercise_mix` line is what prevents
that, and Setup's track select saves on the same line: the queue sends one at
a time and reads each save's version when it is sent, so the second
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
without a reload.

A mix edit can still be waiting to save when that reply arrives: the 400 ms
delay, or a save queued behind another. Applying the reply alone would put the
server's levels back in the form, and the delayed save would then send them,
so the edit would be lost with no notice. So the controller keeps `saved`, the
state the server last confirmed. It starts from the values the server rendered
(`state({ rendered: true })`, read from `defaultValue` and `defaultChecked`),
so an edit the browser restored or made before connect still counts as unsent,
and it moves on every applied server state and every successful save.

When an edit is unsent, each field (weight, exclusion, level or lock) of each
kind that differs from `saved` is an edit (`editsSince`). The reply is applied
and only those fields are set back (`withEdits`). The rebase is per field, not
per kind: moving a kind's weight must not bring back a level target the track
change cleared on that kind. A lock the edit turns on also brings back the
level it was ticked on: the user locked the level they saw, and the track
change may have cleared it on the server meanwhile. A lock left without a
level after the merge is dropped, since the server refuses a lock on an
untargeted kind. The pending
save sends the result under the reply's version, and `saved` stays the reply's
state so a later comparison still sees the edit as unsent.

The reply also carries `kind_rungs`, and `forgetMovedSuggestions` drops any
level-suggestion step whose starting rung the track change moved. Otherwise
the pending save would post a step the server no longer recognizes and get a
409.

The track select saves on this controller's queue line (`line:` in
`code_gym/save_status`). Just before it queues its save it dispatches
`profile-preferences:trackSaving`, which runs `holdForTrackSave`. That does two
things.

It disables the prepare button, since preparing guidance while the levels are
changing would bill jobs for the old ones. `settlePrepareButton` keeps it
disabled while `code_gym/track_reply` reports a track save in flight, which also
covers a mix that connected mid-save and never saw the event.

It also queues a mix edit still inside its 400 ms delay at once, ahead of the
track save. Every mix save that will go out ahead of the track save, the
flushed one and any already waiting in the queue (`waitingSaves`), is frozen to
the edits the form holds at this moment, and the edit revision. A field counts
as edited when the form differs from any state the server might end up with
before this save lands: `saved`, the save on the wire (`onTheWire`), or a frozen
save still queued (`editsFromAnyPending`). Comparing with one of them alone
loses something: `saved` alone misses a weight moved back while its first change
is in flight, and the wire save alone drops a change that save carried if it
then fails. Counting extra fields is safe because a frozen save always goes
out ahead of the one track save that froze it: the track select is disabled
while its save is in flight (`profile_preferences`), so no second track save
can queue ahead of a frozen save, and the server applies the track change after
the frozen edits. When the save is sent, those edits are laid over `saved`
as it is then (`frozenState`, through `withEdits`), and the version and the
shown suggestions are read then too. So an edit made after the track change
cannot ride in the save that goes out ahead of it.
A mix save queued after the track save is not frozen, since it has to read the
form once the track reply has been applied, or it would send targets the track
change cleared. Edits are saved in
the order the user made them: a lock set just before a track change reaches the
server first, so `TrackChange` keeps the target it protects, and a target picked
after the track change, while earlier saves are still queued, stays out of the
pre-track save. That later edit still differs from `saved` when the track
reply arrives, so the rebase keeps it.

The rebase
above is for what is left: an edit made while the track save is in flight, and
an edit made before both controllers connected when `profile-preferences`
connected first and saved the track from its `connect` before this controller
was listening. A track reply that arrived before this controller connected at
all is kept in `code_gym/track_reply`, and `connect` takes and adopts it,
treating an edit made before connect as unsent. Connect order follows module load order, so either can come
first; when this controller connects first, `adoptEarlyEdit` has already set
`pending` and `holdForTrackSave` sends that edit ahead of the track save.

`settlePrepareButton` is the one statement of when the prepare button is
enabled: the latest mix save succeeded (`savedLatest`), no edit is waiting and
nothing is queued on the line. A mix save that replied while a track save
waited behind it saw the line busy and left the button disabled, so the button
is settled again once the track save ends: `adoptTrackChange` on success, which
also sets `savedLatest` since the form now matches the server, and
`profile-preferences:trackFailed` on failure.

One case is left. A save that failed for another reason is no longer pending,
so a later track reply replaces its edit; the save banner already reports that
failure.
