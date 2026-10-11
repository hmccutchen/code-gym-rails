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

`refreshCap` runs after every send attempt, successful or not, and after
Clear. It is the single place that decides whether the input stays usable, so
the in-flight lock set before a fetch and the cap reached after one always end
in the same resting state.

It writes the status only when the cap is reached. It used to clear the status
otherwise, and because it ran in the send path's `finally`, that wiped every
error message right after the `catch` set it, so failures were silent. Callers
that want the status cleared clear it themselves.

## ask

An explicit message, the Explain button's, bypasses the input entirely. An
empty input box is the normal case for it, not a reason to do nothing.

`generation` counts Clears. A reply that comes back after one is dropped,
which is what keeps a cleared thread cleared; Clear has already left the
controls enabled, so the dropped reply does not have to.

## The Enter key

The input's action is `keydown.enter->duck-thread#send:prevent`. The
`:prevent` option is what the handler's own `preventDefault` used to do.
