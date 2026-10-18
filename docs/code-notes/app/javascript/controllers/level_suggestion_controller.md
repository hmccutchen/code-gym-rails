# app/javascript/controllers/level_suggestion_controller.js

## What it owns

The dashboard's level suggestion card, for every account: applying the
proposed levels, removing kinds from a card that lists several, and
dismissing the whole thing.

## Each request carries the moves the card showed

Apply sends `level_suggestion_steps` and a dismissal sends `steps`: each
listed kind with the rung it was shown at (`data-from`) and the rung offered
(`data-to`). The server compares `from` with the stored rung under the row
lock. A skill-level change bumps no preference version, so this is what lets
the server see that a card is stale, and it also decides which event rows are
labelled `suggestion`.

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

## A conflict reloads; a hung or failed save does not

A 409 means the stored version or a shown rung moved, so the page is out of
date and must be read again. Apply and Not now both handle it this way. Reloading over an unfinished save would lose it, so
`reloadWhenSaved` goes through `saveStatus.reloadWhenSaved`, which waits for
`saveStatus.pending()` first. If another save fails meanwhile, or ten seconds
pass, it stops waiting and the card offers a reload button instead. It passes
its own key (`level_apply` or `level_dismissal`) so the refusal that started
the wait does not count as that failure. Either way, a refused proposal can
never leave the page stuck with no way forward.

## No double-wire guard

The inline script this replaced set `data-wired` on its element, because the
partial could render more than once per page. Stimulus connects one
controller instance per element, so the guard has no job here.

## Steps are hidden, not removed

Removing a kind from the card hides its element and leaves it in the DOM, because
Apply needs the removed kinds to dismiss them. `listed()` and `removed()`
read that one piece of state, and nothing else records it.
