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

## The server renders the first value

The server writes the selected option's text into the span, so a row shows
its value before the module loads, after a failed load, and with scripts off.
The view builds each option list once and reads both the select's options and
the span's text from it (`rassoc` on the saved value), so the two can't name
different labels. The time zone row falls back to the detect-automatically
label when no zone is saved. On connect the controller writes the same text
again, which changes nothing; after that, only a `change` moves it.

With scripts off, a changed but unsaved Exercise language still shows the
saved value until Save key posts the form. Keeping the native select visible
until the script runs would cover that case, but it changes the overlay
design, and the user chose to keep the overlay (PR #512 review).

## Other controllers on the same select

A select can also save through another controller, as the time zone and Track
selects do through `profile-preferences`. Both actions sit on one
`data-action`, and this controller only reads the select, so neither depends
on the other.
