# `app/assets/javascripts/code_gym_bootstrap.js`

## What it is for

Before #357, `shared/_request` and `shared/_save_status` rendered into `<head>`
as inline classic scripts, so `window.CodeGymRequest` and
`window.CodeGymSaveStatus` existed from the moment the parser passed them —
earlier than any element a user could click. Step 1 replaced those two renders
with `javascript_importmap_tags`, which emits `<script type="module">`. A
module is always deferred: it executes after parsing ends and after its own
fetch. Everything the browser paints before that point is interactive, and a
page script reaching either global in that window gets a `ReferenceError`.

The dashboard is where that costs the most. Its submit handler calls
`preventDefault`, sets the form `inert` and disables the button, and only then
awaits `CodeGymRequest.send`. The throw skips the restore block, so the button
stays on "Submitting…", the form stays inert and no native submission happens
either. The day is stranded with nothing saved.

This file restores the old guarantee in one place. It is served by Propshaft
and included with `javascript_include_tag` immediately before the importmap
tags, which makes it a blocking classic script: it runs during parse, before
`<body>` exists. It installs stubs that record calls instead of making them,
and `application.js` calls `CodeGymBootstrap.flush()` once the real modules are
assigned.

## The stub surface

The stubs mirror the two modules' exports, because a partial surface would turn
one `ReferenceError` into another.

`CodeGymRequest.send` and `.get` are async in the module, so the stub returns a
promise that resolves to the real call's result after the flush. The caller
awaits it and cannot tell the difference beyond the delay it was already
prepared for.

`CodeGymSaveStatus` is mixed, and the split is what the design turns on.
`save` and `queue` are async and queue like the request methods. `queued(key)`
and `pending()` are **synchronous predicates read in boolean context**, so they
can never return a promise — a promise is always truthy, which would make
`pending()` report work forever and `queued()` report a save that is not
there. The stub therefore keeps its own count of calls it is holding: `save`
and `queue` increment a per-key counter, and both the fulfilled and the
rejected path decrement it, so a failed call cannot leave `pending()` stuck
true and block pull-to-refresh.

The counted argument sits in a different position per method —
`save(method, url, body, key, …)` holds it at index 3 and
`queue(key, method, url, body, options)` at index 0 — which is why `tracked`
takes the index rather than assuming one.

`watch(probe)` is recorded locally so `pending()` can consult it straight away,
and replayed to the real module at flush so it keeps working afterwards.
`carry`, `report` and `clear` are plain forwards; every call site ignores their
return value.

`flush()` drains the queue in call order, so a page script's own sequencing
survives.

## Why this shape

A per-call-site `DOMContentLoaded` gate was the alternative and is worse here.
It touches about fourteen views for a hazard that is one fact about module
loading, and #357's step 3 deletes every one of those views' scripts anyway.

Binding the listeners late instead is worse still. A handler whose whole job is
`preventDefault` means that, while it is missing, the browser performs a native
full-page form submission rather than doing nothing.

A forwarding `Proxy` cannot work, for the reason the predicates give above: it
would have to answer `queued` and `pending` synchronously without knowing the
answer.

CSS gating does not hold either — `pointer-events: none` leaves keyboard
activation untouched.

## Its lifetime

This file is transitional. #357's step 3 converts the last inline page script
to a Stimulus controller, at which point `data-action` binds through Stimulus's
own lifecycle and the window this covers stops existing. The two `window.*`
aliases in `application.js` go at the same time, and this file goes with them.

## What holds it

`spec/system/deferred_module_spec.rb` stalls the module assets, navigates with
`waitUntil: "commit"`, asserts the document is still `interactive`, clicks
Submit inside that window and expects the review to arrive. It fails without
this file.
