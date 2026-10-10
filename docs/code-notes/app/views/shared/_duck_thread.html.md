# app/views/shared/_duck_thread.html.erb

## The partial

A pre-submission thinking partner for one section. The conversation lives only
in this tab's memory and is sent back in full on every request as prompt
context; nothing is written on the server. The partial renders only from an
unsubmitted section, and once the day is submitted it is not rendered again,
so there is nothing to clean up.

## Visually hidden input label

The input has a real label, hidden visually, because a placeholder is not a
label: it disappears once typing starts, and some screen readers skip it.

## Explain button

The Explain button sends a fixed message on the user's behalf, so getting an
explanation does not depend on knowing how to phrase a request for one. It
goes through the same endpoint as any other turn and counts against the same
cap.

## Script emitted once per page

The partial can render once for each section on the page, so the script is
emitted once into the layout's shared `:page_scripts` region rather than
inline, with the same reasoning and guard pattern as `shared/_ai_review`'s
script. The `[data-duck-thread]:not([data-duck-wired])` guard lets the single
copy wire every instance, whichever render emitted it.

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
otherwise, and because it runs in `sendMessage`'s `finally`, that wiped every
error message right after the `catch` set it, so failures were silent. Callers
that want the status cleared clear it themselves.

## sendMessage

An explicit message, the Explain button's, bypasses the input entirely. An
empty input box is the normal case for it, not a reason to do nothing.
