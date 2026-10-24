# app/javascript/controllers/value_row_controller.js

## What it owns

A value row shows a label and the chosen value, and a tap opens the phone's
own picker. The controller copies the selected option's text into the row's
visible span, once on connect and again on every `change`.

## Why the select is overlaid

The real `<select>` sits over the whole row with zero opacity, so the tap
reaches a native control and the phone shows its own picker, with its own
accessibility behavior. A select cannot be styled to look like a label with a
value beside it, so the span carries the text the eye reads. The span is
`aria-hidden`, because the select and its label already speak for the row.

## Why connect runs `show()`

The server renders the span empty. Writing the text from the select's
selected option on connect means the controller is the only place that decides
what the span says, and a select the server marked as selected needs no
second copy of its label in the markup.

## Other controllers on the same select

A select can also save through another controller, as the time zone and Track
selects do through `profile-preferences`. Both actions sit on one
`data-action`, and this controller only reads the select, so neither depends
on the other.
