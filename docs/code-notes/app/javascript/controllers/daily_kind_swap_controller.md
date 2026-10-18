# app/javascript/controllers/daily_kind_swap_controller.js

The `daily-kind-swap` controller on each daily card's swap row. It opens and
closes the picker, shows the summary the server rendered for the chosen
option, posts the swap, and puts the server's reply on the page.

## It holds no rule

Which options are disabled, every consequence sentence, the warning and the
reply sentence are rendered by the server. The script only reads
`data-state` on a radio to decide whether Confirm may be enabled, and that
attribute is the server's answer too.

## Saving goes through `CodeGymSaveStatus.save`

A failure (the 409 for a page that is out of date, or a 422 refusal) shows
in the shared `#save-status` banner like every other save on the page. The
picker stays open and focus goes back to Confirm, so the reader can cancel or
reload without hunting for where they were.

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
