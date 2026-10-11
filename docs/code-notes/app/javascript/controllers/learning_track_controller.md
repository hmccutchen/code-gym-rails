# app/javascript/controllers/learning_track_controller.js

## What it owns

Setup's learning-track block: the "Suggest level changes" checkbox and the
button that leaves the track.

## The checkbox is reverted, not optimistic

A checkbox shows its new state the moment it is clicked, before anything is
saved. If the save fails the control is lying, so the controller keeps
`savedSuggestions` as the last state the server confirmed and writes it back
once nothing is still queued under that key. The queued check is what keeps a
fast second click from being reverted by the first click's reply.

## Leaving settles in place rather than reloading

A reload here would cancel the Exercise mix's delayed save or hide its
failure, and both sit on the same page. So the block replaces itself with a
confirmation line, which takes focus because the button that had it is gone.

The key guide is removed at the same time because it renders only for an
account on the track.
