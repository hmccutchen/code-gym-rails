# app/javascript/controllers/learning_track_controller.js

## What it owns

Setup's learning-track block: the button that leaves the track. The "Suggest
level changes" switch used to live here; it now belongs to every account and
sits in the Exercise mix (`level_suggestions_setting_controller.js`).

## Leaving settles in place rather than reloading

A reload here would cancel the Exercise mix's delayed save or hide its
failure, and both sit on the same page. So the block replaces itself with a
confirmation line, which takes focus because the button that had it is gone.

The key guide is removed at the same time because it renders only for an
account on the track.
