# app/javascript/controllers/level_suggestions_setting_controller.js

## What it owns

The "Suggest level changes" switch in Setup's Exercise mix, which every
account has. The dashboard card's "turn these suggestions off" link opens the
Exercise mix (`?show=level_suggestions`) and jumps to it, since the switch
sits inside a closed disclosure.

## The checkbox is reverted, not optimistic

A checkbox shows its new state the moment it is clicked, before anything is
saved. If the save fails the control is lying, so the controller keeps
`saved` as the last state the server confirmed and writes it back once
nothing is still queued under that key. The queued check is what keeps a
fast second click from being reverted by the first click's reply.

## An edit made before the modules load

`saved` seeds from `defaultChecked`, not `checked`: the box may already have
been clicked while the deferred modules were loading, and seeding from its
current state would record an unsaved change as saved and then silently keep
it. When the two differ, `connect()` sends the save the missing listener
would have sent.
