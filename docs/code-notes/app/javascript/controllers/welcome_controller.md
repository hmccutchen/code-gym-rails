# app/javascript/controllers/welcome_controller.js

## What it owns

The first-run question at `/welcome`: one choice of track, one PATCH, then
Setup. Each button posts `choose_track: true` with its level, which
`ProfileController` checks under the user-row lock and `User#choose_track`
records. The levels come from `LevelSuggestion::LADDER`, so principal
engineer is never offered here; Setup sets it by hand.

## Focus

A failed save puts focus back on the button that was pressed, since disabling
it while the request ran dropped focus to the page. The pressed button comes
from the click event, since Safari does not focus a button on click.

## Every button disables together

A choice is a one-way write, so a second click while the first is in flight
would post a second one. A failed save re-enables them, so a refused choice
can be retried without a reload.
