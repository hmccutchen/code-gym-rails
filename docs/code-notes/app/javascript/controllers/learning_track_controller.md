# app/javascript/controllers/learning_track_controller.js

## What it owns

Setup's learning-track block: the button that leaves the track. The
"Suggest level changes" checkbox moved to the Exercise mix and its own
controller, `level_suggestions_switch_controller.js`, when suggestions opened
to every account.

## Leaving settles in place rather than reloading

A reload here would cancel the Exercise mix's delayed save or hide its
failure, and both sit on the same page. So the block replaces itself with a
confirmation line, which takes focus because the button that had it is gone.

The key guide is removed at the same time because it renders only for an
account on the track.
