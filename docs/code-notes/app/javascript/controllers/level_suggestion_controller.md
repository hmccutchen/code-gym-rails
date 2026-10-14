# app/javascript/controllers/level_suggestion_controller.js

## What it owns

The dashboard's level suggestion card: applying the proposed levels,
removing kinds from a card that lists several, and dismissing the whole thing.

## Two writes, not one transaction

Apply saves the listed kinds' new levels through `PATCH /profile`, then
dismisses the removed ones separately, with `reason: "removed"`; Not now
sends `reason: "not_now"`. The reason only labels the server's record of the
dismissal, and both set the same cutoff. The level save and the dismissal
are not atomic: if the dismissal fails, the levels are still saved and the
shared save banner shows the failure. That is the project's stated behavior, not an accident of this file.

The answer count is a third write, and it is deliberately not waited on — a
lost count delays the switch to Setup without undoing the choice, which is
why its failure text says the choice was saved.

## A conflict reloads; a hung save does not

A 409 means the stored version moved, so the page is out of date and must be
read again. Reloading over an unfinished save would lose it, so
`reloadWhenSaved` polls `saveStatus.pending()` first. Past ten seconds it
stops polling and offers a reload button instead, so a refused proposal can
never leave the page stuck with no way forward.

## No double-wire guard

The inline script this replaced set `data-wired` on its element, because the
partial could render more than once per page. Stimulus connects one
controller instance per element, so the guard has no job here.

## Steps are hidden, not removed

Removing a kind from the card hides its element and leaves it in the DOM, because
Apply needs the removed kinds to dismiss them. `listed()` and `removed()`
read that one piece of state, and nothing else records it.
