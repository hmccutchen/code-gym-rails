# app/javascript/controllers/follow_ups_controller.js

## What it owns

One reviewed section's follow-up thread: the input, the send button, Enter, the
turns it appends and the cap that replaces the form.

## Both controls lock together

`disableControls` is the one place the input and the button change state, so an
in-flight request and a failed one always leave the pair agreeing. A failure
unlocks both; reaching the cap removes the form instead, which is why the cap
path does not unlock first.

## The cap paragraph is rendered twice over

The server renders it when the section arrives already at the cap, and the
controller builds the same paragraph when the last follow-up lands. The text
reaches the controller as a value, so the two cannot drift.
