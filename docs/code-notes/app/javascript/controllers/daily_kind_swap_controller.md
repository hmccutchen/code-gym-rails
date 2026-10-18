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

The request names the exercise the page shows (`exercise_id`), and the
server renders the panels for that row. A dashboard left open past midnight,
before the next set exists, still gets its panels back. If a reply has no
panel for this card anyway, the controller clears its busy state itself, so
Cancel and Confirm never stay disabled.

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
on this page describe settings that are no longer stored. The 409 reply
carries the same freshly rendered panels a save does, the controller swaps
them in and reopens this card's picker on the stored pair, with focus on its
checked radio. The next Confirm posts the stored version and saves. This is
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
