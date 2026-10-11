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

The dashboard was where that cost the most, before its submit handler moved
into `answer_form_controller`: the inline handler set the form `inert` before
awaiting `CodeGymRequest.send`, so the throw stranded the day with nothing
saved. The inline scripts that remain still reach the globals from handlers
bound at parse time. The layout's name editor calls `CodeGymSaveStatus.queue`
on blur and Setup's controls call it on change, so a blur or a change in that
window would throw and lose the save.

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

## The early-edit recorder

The stubs above cover a page script that *calls* one of the globals. An edit
typed before the modules arrive calls nothing at all, and that is the commoner
case: the HTML parses, the user starts typing, the module lands a couple of
hundred milliseconds later.

Before #357 the dashboard's inline script bound its own `input` listener and
registered `watch(() => saveTimer !== null)` during parse, so a keystroke in
that window was already pending work. A Stimulus controller registers both in
`connect()`, which runs only once the modules have loaded, so the keystroke
fell into a hole: pull-to-refresh saw nothing pending and could reload over it,
and no later `input` event existed to schedule the save.

So the bootstrap listens for `input` and `change` on `document` in the capture
phase and sets `early.dirty` when the event came from inside a
`[data-controller]` region. It registers that flag through its own `watch`,
which means `pending()` answers true straight away and the real `save_status`
inherits the same probe at flush.

That selector rather than `form` is what makes the flag match who can clear
it. Setup's Exercise mix autosaves a slider that sits in no form at all, so a
form gate recorded nothing there, while a control outside every controlled
region has nobody to adopt it on connect and would hold `pending()` true until
settling.

Two halves finish the job, and neither belongs here. `application.js` settles
the recorder only once every controller on the page has connected and taken
over; settling in `flush()` would open a gap between the globals being assigned
and Stimulus connecting, in which the edit is pending to nobody.

`application.start()` resolving is not that moment.
`eagerLoadControllersFrom` fires one dynamic `import()` per controller and
awaits none of them, so start resolves while any number of controllers are
still loading — settling there cleared the flag and unbound the recorder with
the controller that owned the edited field not yet connected, and a
pull-to-refresh in that window reloaded over the edit. So `application.js`
waits for `application.getControllerForElementAndIdentifier` to answer for
every identifier named by a `[data-controller]` element on the page, and
exposes the result as `window.CodeGymBootstrap.ready`. A controller whose
module never arrives would hold the edit pending for the rest of the page's
life, so the wait gives up after ten seconds and settles anyway.

Settling removes the two listeners as well as clearing the flag. Leaving them
bound would set `dirty` again on the next keystroke with nothing left to clear
it, so `pending()` would answer true for the rest of the page's life and every
caller that waits on it — pull-to-refresh, the save queue's drain — would wait
forever. And a controller that owns an edited field schedules the save itself on
connect — `answer_form_controller` compares each textarea's `value` with its
`defaultValue`, which is exactly the server-rendered content, so a difference
means the user typed. Without that the answer is not saved promptly; the spec
below takes four minutes instead of five seconds.

`exercise_mix_controller` does the same in its own terms: a range input is
compared with its `defaultValue` and a checkbox or radio with its
`defaultChecked`, and a difference re-syncs the slider label, the disabled
states and the group lock before saving, since none of that ran while the
modules were loading.

A controller with no such check leaves its field unsaved until the user touches
it again, which is the pre-#357 behaviour for every control that had no inline
listener, so this is a per-controller decision rather than something the
bootstrap can do for everyone.

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

The stub surface is transitional. #357's step 3 converts the last inline page
script to a Stimulus controller, at which point `data-action` binds through
Stimulus's own lifecycle and nothing reaches the globals during parse any more.
The two `window.*` aliases in `application.js` go at the same time, and the
stubs go with them.

The early-edit recorder stays. It is not about inline scripts at all — it is
about the gap between a parsed page and a loaded module, which no amount of
converting views removes. Step 4 shrinks this file to that recorder rather than
deleting it.

## What holds it

`spec/system/deferred_module_spec.rb` stalls the module assets, navigates with
`waitUntil: "commit"` and asserts the document is still `interactive`. Inside
that window it moves a Setup slider, whose save is queued through the stub
before the modules arrive, and expects `queued()` and `pending()` to answer
true at once and the save to land once the flush replays it. That example
fails without this file.

The same spec types an answer on the dashboard in that window and expects it
counted as pending and then saved, which is the early-edit recorder's job. It
also clicks Submit in that window and expects nothing to be posted, since the
button is not a submit button until `answer_form_controller` connects.
