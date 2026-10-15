# app/javascript/controllers/welcome_controller.js

## What it owns

The first-run question at `/welcome`: two steps, one PATCH, then Setup.
"Early in my career" saves at once. "Experienced" saves nothing; it shows a
second step asking for the starting level, and the chosen level posts
`learning_track: "none"` and `skill_level` together.

## Why the second step stays in the browser

`User#first_run?` ends once any `learning_track` is saved, and `/welcome`
redirects as soon as it does. Saving `none` first would end the page before
the level was asked, so nothing is sent until the level is chosen. Back
returns to the first step without a request.

## Focus

Opening the level step moves focus to its heading, and Back returns it to
the Experienced button, so a screen reader user lands where the content
changed. A failed save puts focus back on the button that was pressed, since
disabling it while the request ran dropped focus to the page.

## The whole preset is posted, not a flag

`PATCH /profile` refuses a junior choice that does not carry the exact
registry-derived preset and the track's starting skill level, under the
current preference version. So the server renders all three as values and the
controller posts them back unchanged. The controller holds no copy of what
the preset is.

## Every button disables together

Every choice is a one-way write, so a second click while the first is in
flight would post a second one. A failed save re-enables them, which is what
makes a refused version recoverable without a reload.
