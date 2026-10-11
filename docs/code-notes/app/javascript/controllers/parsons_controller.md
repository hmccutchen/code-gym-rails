# app/javascript/controllers/parsons_controller.js

## What it owns

One Parsons section: the block list, drag through SortableJS, the keyboard
path, the injected arrow fallback, the live-region announcement and the hidden
answer field. It replaces two inline scripts — a classic one and a module one
that handed work back through `list.parsonsSync` and `list.parsonsAddControls`
expandos. A controller holds both halves, so neither expando survives.

## The markers sit on listTarget, not this.element

`data-parsons-wired` and `data-sortable-done` are written onto the `<ol>`.
The controller element is a wrapper `<div>`, added because a Stimulus target
must be a descendant of its controller and the status line and hidden field
are siblings of the list. Specs read
`ol[data-parsons-blocks][data-parsons-wired]` and
`ol[data-parsons-blocks][data-sortable-done]`, and those selectors keep their
meaning: wired is set in `connect()`, which is exactly when the listeners are
live, and sortable-done only after the import resolves.

## The timer is load-bearing, the catch alone is not

A CDN that hangs never rejects, so `catch` would leave the section with no
drag and no arrows — unanswerable. `DRAG_FALLBACK_MS` injects the arrows after
three seconds whenever `data-sortable-done` is still absent. Both paths end in
`addControls`, which is idempotent through `data-parsons-controls`.

## SortableJS is imported by absolute URL

There is no `pin` for it in `config/importmap.rb`. A dynamic `import()` of the
full jsDelivr URL needs no map entry, and leaving it out keeps the dependency
visible at its one call site. The URL has to stay byte-identical: the system
spec intercepts it by glob to drive both fallback branches.

## disconnect destroys Sortable

The inline script never did, because its listeners died with the page. A
controller can be disconnected while the page lives, so the instance is torn
down with it.
