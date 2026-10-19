# app/javascript/controllers/daily_kind_swap_controller.js

The `daily-kind-swap` controller on each daily card. It opens and closes the
card's swap sheet, shows the example and consequence block the server
rendered for the checked kind, posts the swap, and puts the server's reply
on the page.

## It holds no rule

Which options are disabled, every badge, every consequence sentence, the
warning, each kind's primary button label and the reply sentence are
rendered by the server. The script only reads `data-state` on a radio to
decide whether the primary button may be enabled, and copies the checked
radio's `data-confirm-label` onto it; both are the server's answers too.

## The sheet is a modal `<dialog>`

`open` calls `showModal()`, which makes the rest of the page inert and puts
the sheet in the top layer, so no ancestor's transform (pull-to-refresh's
resume) moves it and no `z-index` competes with the tab bar or the banner.
Focus goes to the checked radio, or to Close when an ended trial left no
list.

Every way out goes through `dismiss`: Close, Cancel, Done, the dialog's
`cancel` event (Escape) and a backdrop click. It resets the choice to the
current kind, closes the sheet and focuses the trigger itself rather than
leaving that to the browser, since Safari and Chrome return focus
differently. `dismiss` does nothing while a swap is saving, and `escape`
always calls `preventDefault`, so Escape is ignored until the reply lands.

A click on the `::backdrop` is dispatched to the dialog element. The dialog
has no padding and one wrapper fills it, so a click whose target is the
dialog came from outside the sheet. A drag that starts inside the sheet and
ends on the backdrop, such as selecting text, also produces a click on the
dialog, because the dialog is the nearest ancestor of both ends. `press`
records whether the `pointerdown` landed on the dialog, and `backdrop`
dismisses only when both did.

Chrome closes a modal dialog on a second Escape even after the page refused
the first, when there has been no user activation in between. `closed`
handles a `close` the controller didn't ask for: it clears `wanted`, resets
the choice unless a swap is saving, and focuses the trigger. A swap left
saving that way finishes in the queue as usual. That close is also why two
swaps can still overlap, and why the queue below matters.

## Swaps go one at a time through `CodeGymSaveStatus.queue`

Every card's controller queues on the one `daily_kind_swap` line, under a
status key of its own (`daily_kind_swap:<url>`). The shared line keeps the
swaps in order; the separate keys keep one card's failure in the banner
when the other card's swap then saves, until the failed card saves. Two
confirms in quick succession, on two cards, would otherwise post the same
version: the second would get a 409, and `save` would drop the first reply
even though that swap was saved. The body is a function the queue calls
when it sends, so a queued swap reads the version from its panel after the
earlier reply has replaced it. While a swap of this card is queued or on
the wire, the primary button, Cancel and Close are disabled, the list is
`inert`, and a panel re-rendered by another card's reply keeps showing
"Saving…".

## The page's set, not today's

The request names the exercise the page shows (`exercise_id`) and its
generation (`draft_scope`, the id plus `generated_at`, the same token the
answer form posts). The server renders panels only for that generation. A
dashboard left open past midnight, before the next set exists, still gets
its panels back. A set another tab regenerated keeps its id but not its
scope, so the reply carries no panels and a `set_changed` sentence instead:
the old cards would otherwise take panels built for the new set's kinds.
The controller then leaves the cards as they are, clears its busy state,
closes the sheet and shows the sentence on the card, which asks for a
reload. It never reloads by itself, so typed answers are not lost. The same
applies to a stale 409 and to an id the server can't find.

## The reply replaces both panels

A save bumps `section_kind_preferences_version` and changes which options the
other place can offer (the new kind is now "Already daily" there). The reply
carries a freshly rendered panel for every delivered daily card, and the
controller swaps each one in by id. Both cards then post the new version, so
a second swap from the same page works without a reload. The card's live
region sits outside the panel, so an announced sentence survives the
replacement.

Each panel holds its card's trigger, the stored-kind line, the first-time
hint and the dialog, so replacing a panel removes an open sheet from the
page. `wanted` records whether this card's sheet should be open; when a
panel is replaced and its sheet was wanted, `panelTargetConnected` shows the
new one. Targets are read from the DOM on each access, so a reply handler
that runs before Stimulus sees the new panel already works on it.

## Saved, and "Want it today?"

When the reply carries `want_it_today`, the sheet stays open in its saved
state: the list, the next-set line and the consequence blocks are hidden,
the reply's sentence and the want-it-today line show in their place, and
Done replaces the two buttons and takes focus. Done's `aria-describedby`
names both lines, so a screen reader reads them with it. The offer appears
only after a save, so regenerating never sits next to the swap as a second
choice before anything is saved.

The link only closes the sheet and focuses the existing "Generate new set"
button. That button keeps its own confirmation and states the cost, so the
sheet never starts a regeneration itself.

Without `want_it_today`, the sheet closes, focus returns to the trigger and
the sentence is announced in the card's polite live region, visually
hidden, since the stored-kind line under the title row now shows the change.

## Failures

A failure shows in the shared `#save-status` banner like every other save on
the page, because the leave gate reads it, and in the sheet's own error line,
because the banner sits behind the scrim. On a refusal or a request that
never got a usable reply, the sheet stays open or opens again, even when
another card's reply re-rendered this panel while the swap waited in the
queue. The submitted kind is checked again only if the current panel still
offers it, and focus goes to the primary button when it is enabled,
otherwise to the checked radio. So two cards that both chose Coding
Challenge leave the second open on its current kind, and a 503 leaves the
choice in place for one more try.

A 409 means another tab changed the pair or the Exercise mix, so the panels
on this page describe settings that are no longer stored. When the set on
the page is still current, the 409 reply carries the same freshly rendered
panels a save does, and the controller swaps them in and keeps this card's
sheet open on the stored pair, with focus on its checked radio and the
message in the error line. Each card keeps the kind of its last unsaved
attempt. Whenever its panel is replaced, by its own reply or another card's,
it reconciles: if the panel now shows that kind as stored, an earlier
attempt saved it and only its reply was lost, so the card clears its failure
(and, on its own 409, closes the sheet). A different stored kind keeps the
failure, so the page still won't leave past it, and a card with a swap still
queued doesn't reconcile until its own reply comes back. The next try posts
the stored version and saves. This is the card's counterpart to Exercise mix
reloading on `layout_changed`; the card can refresh in place because its
whole state is one server-rendered panel.

## Radios outside `#gym-form`

Each radio names `form="daily-kind-swap"`, an empty form outside the answer
form, so the day's submit never posts it. Its `change` event still bubbles to
`answer-form`, which ignores anything without `data-field`.

## A reply moves focus only if focus was the card's

A reply can arrive long after the swap was sent, when the reader has left
the sheet and is typing an answer. So when a reply arrives, the card notes
where focus is. It may move focus or show its sheet only if focus was inside
this card, or nowhere because this card's own button was disabled for the
save it last sent (`lastConfirmed`). A modal can't open without taking
focus, so otherwise the sheet stays closed and the failure stays in the
banner, with the submitted kind still checked for the next open. If a reply
replaces another card's panel that held focus on its trigger, the
replacement would drop it, so `replacePanels` moves it to that card's new
trigger. Opening and closing the sheet by hand always focus as before.
