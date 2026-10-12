# app/javascript/controllers/welcome_controller.js

## What it owns

The first-run question at `/welcome`: two buttons, one PATCH, then Setup.

## The whole preset is posted, not a flag

`PATCH /profile` refuses a junior choice that does not carry the exact
registry-derived preset and the track's starting skill level, under the
current preference version. So the server renders all three as values and the
controller posts them back unchanged. The controller holds no copy of what
the preset is.

## Both buttons disable together

Either choice is a one-way write, so a second click while the first is in
flight would post a second one. A failed save re-enables them, which is what
makes a refused version recoverable without a reload.
