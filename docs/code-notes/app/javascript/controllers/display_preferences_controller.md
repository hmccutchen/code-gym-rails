# app/javascript/controllers/display_preferences_controller.js

## What it owns

Setup's Display disclosure: theme, background pattern, text size, line
spacing and the reading font. One change handler on the whole disclosure, so
every radio is covered without a listener each.

## It applies first, then saves

A display choice is about what the page looks like, so waiting for a round
trip to show it would be the wrong order. `apply` writes the same `<html>`
attributes the layout renders from stored values, which is the one thing in
this file that has to change whenever the layout's rendering does.

## Queued, because each save carries the whole object

`display_preferences` is a single jsonb column, so every save posts all five
settings. Parallel saves could land out of order and store an older set, so
they go through `saveStatus.queue` under one key, and the body is a function
read when the save is sent rather than when it is queued.

## An edit made before the modules load

Nothing here is bound until `connect()`, which waits on the deferred module
graph, so a theme or text-size radio clicked before then fires at no one.
`connect()` looks for a checked radio the server did not render checked and
runs `change()` for it, which both applies the attributes to the page and
queues the save.
