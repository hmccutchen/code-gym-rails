# app/javascript/controllers/duck_thread_controller.js

## What it owns

One section's thinking partner: the disclosure, the turn list, the send and
Explain buttons, Clear, and the cap. The markup it drives, and why the server
strings arrive as Stimulus values, are in
`docs/code-notes/app/views/shared/_duck_thread.html.md`.

## It imports the request module

The controller imports `code_gym/request` rather than reading
`window.CodeGymRequest`. That import is the reason this conversion needed the
importmap step first: an inline script had no way to ask for a module.

## Speaker label

Each turn carries a visually hidden speaker label. Otherwise the speaker shows
only through CSS colour, which assistive tech, and anyone not perceiving
colour, never receives. Hiding it visually leaves the styled transcript
unchanged.

## refreshCap

`refreshCap` runs after every send whose reply is still current, successful or
not, and after Clear. A reply dropped because Clear ran while it was in flight
returns before it, which is correct: Clear has already left the controls in
their resting state. It is the single place that decides whether the input
stays usable, so the in-flight lock set before a fetch and the cap reached
after one always end in the same resting state.

It writes the status only when the cap is reached. It used to clear the status
otherwise, and because it ran in the send path's `finally`, that wiped every
error message right after the `catch` set it, so failures were silent. Callers
that want the status cleared clear it themselves.

## connect

A thread restored from the server is drawn and capped on connect, so a reload
at the cap shows the cap text and disabled controls, as before the reload.
With no stored thread it touches nothing.

## clear and clearing

Clear empties the page at once, as it always has, then sends the DELETE. The
pending request is kept as `clearing`, and `ask` waits for it before sending,
so an ask doesn't carry a version the Clear is about to retire. An ask that a
Clear overtook while it waited is dropped before it is sent, since the server
would otherwise store a turn the page no longer shows. A second Clear while
one is pending empties the page again but shares the pending request, so two
replies can't arrive out of order and rewind the version. A failed clear
puts the thread back on the page before it shows the send-failed text, since
the server still holds it; leaving the page empty would hide history the duck
still answers from. It also restores `generation` to its value before the
Clear and keeps any reply that came back for an ask sent before it
(`overtaken`), because the server stored that reply. Without both, the page
would sit a version behind and the next message would be refused. Both
requests go
through `request.send` rather than the save queue; the decision doc says why.

## draftScope

The set's draft scope is already rendered on the answer form that wraps every
duck, for autosave. The duck reads it from there instead of carrying a copy of
its own, so a section's markup stays as it was, and sends it with every ask
and Clear so the server can refuse a page showing a set that is no longer
today's.

## ask

An explicit message, the Explain button's, bypasses the input entirely. An
empty input box is the normal case for it, not a reason to do nothing.

Each ask sends the version from the last reply, or the one rendered onto the
page. The server refuses a version that has moved, which is how two devices
or a Clear mid-flight are kept apart.

`generation` counts Clears. A reply that comes back after one is dropped,
which is what keeps a cleared thread cleared; Clear has already left the
controls enabled, so the dropped reply does not have to.

## The Enter key

The input's action is `keydown.enter->duck-thread#send:prevent`. The
`:prevent` option is what the handler's own `preventDefault` used to do.
