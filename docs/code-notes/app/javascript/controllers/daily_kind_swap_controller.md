# app/javascript/controllers/daily_kind_swap_controller.js

The `daily-kind-swap` controller on each daily card's swap row. It opens and
closes the picker, shows the summary the server rendered for the chosen
option, posts the swap, and puts the server's reply on the page.

## It holds no rule

Which options are disabled, every consequence sentence, the warning and the
reply sentence are rendered by the server. The script only reads
`data-state` on a radio to decide whether Confirm may be enabled, and that
attribute is the server's answer too.

## Swaps go one at a time through `CodeGymSaveStatus.queue`

Every card's controller queues on the one `daily_kind_swap` line, under a
status key of its own (`daily_kind_swap:<url>`). The shared line keeps the
swaps in order; the separate keys keep one card's failure in the banner
when the other card's swap then saves, until the failed card saves. Two
confirms in quick succession, on two cards or after changing the radio on
one, would otherwise post the same version: the second would get a 409, and
`save` would drop the first reply even though that swap was saved. The body
is a function the queue calls when it sends, so a queued swap reads the
version from its panel after the earlier reply has replaced it. Confirm
stays disabled while a swap of this card is queued or on the wire, and a
panel re-rendered by another card's reply keeps showing "Saving…".

## The page's set, not today's

The request names the exercise the page shows (`exercise_id`) and its
generation (`draft_scope`, the id plus `generated_at`, the same token the
answer form posts). The server renders panels only for that generation. A
dashboard left open past midnight, before the next set exists, still gets
its panels back. A set another tab regenerated keeps its id but not its
scope, so the reply carries no panels and a `set_changed` sentence instead:
the old cards would otherwise take panels built for the new set's kinds.
The controller then leaves the cards as they are, clears its busy state,
closes the picker and shows the sentence, which asks for a reload. It never
reloads by itself, so typed answers are not lost. The same applies to a
stale 409 and to an id the server can't find.

## Failures

An ended trial's picker has no radios, so opening it focuses Cancel, which
sits inside the fieldset, so Escape still closes it.

A failure shows in the shared `#save-status` banner like every other save on
the page. On a refusal or a request that never got a usable reply, the
picker reopens, even when another card's reply re-rendered this panel
closed while the swap waited in the queue. The submitted kind is checked
again only if the current panel still offers it, and focus goes to Confirm
when it is enabled, otherwise to the checked radio. So two cards that both
chose Coding Challenge leave the second open on its current kind, and a
503 leaves the choice in place for one more Confirm.

A 409 means another tab changed the pair or the Exercise mix, so the panels
on this page describe settings that are no longer stored. When the set on
the page is still current, the 409 reply carries the same freshly rendered
panels a save does, and the controller swaps them in and reopens this card's
picker on the stored pair, with focus on its checked radio. Each card keeps
the kind of its last unsaved attempt. Whenever its panel is replaced, by its
own reply or another card's, it reconciles: if the panel now shows that kind
as stored, an earlier attempt saved it and only its reply was lost, so the
card clears its failure (and, on its own 409, closes the picker). A
different stored kind keeps the failure, so the page still won't leave past
it, and a card with a swap still queued doesn't reconcile until its own
reply comes back. The next Confirm posts the stored version and saves. This is
the card's counterpart to Exercise mix reloading on `layout_changed`; the
card can refresh in place because its whole state is one server-rendered
panel.

## The reply replaces both panels

A save bumps `section_kind_preferences_version` and changes which options the
other place can offer (the new kind is now "Already a daily section" there).
The reply carries a freshly rendered panel for every delivered daily card,
and the controller swaps each one in by id. Both cards then post the new
version, so a second swap from the same page works without a reload. The
reply region sits outside the panel, so the announced sentence survives the
replacement.

## The want-it-today link

The link only scrolls to and focuses the existing "Generate new set" button.
That button keeps its own confirmation and states the cost, so the swap row
never starts a regeneration itself.

## Radios outside `#gym-form`

Each radio names `form="daily-kind-swap"`, an empty form outside the answer
form, so the day's submit never posts it. Its `change` event still bubbles to
`answer-form`, which ignores anything without `data-field`.

## A reply moves focus only if focus was the card's

A reply can arrive long after Confirm, when the reader is typing an answer.
So when a reply arrives, the card notes where focus is. It may move focus
(to its trigger, its reopened picker or Confirm) only if focus was inside
this card, or nowhere because this card's own Confirm was disabled for the
save it last sent (`lastConfirmed`). Otherwise focus stays where the reader
put it. If a reply replaces another card's panel that held focus, the
replacement would drop it, so `replacePanels` moves it to that card's new
trigger. Opening and closing the picker by hand always focus as before.

