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

## One instance per section

The partial can render once for each section on the page, and each render is
its own `duck-thread` controller instance with its own thread. Stimulus
connects every element carrying the controller, so there is no once-per-page
script to emit and no already-wired guard to keep. That guard, and the
`:page_scripts` region the script used to be emitted into, are gone.

## Everything the controller needs is on the element

A controller is an ES module, so it cannot read a translation or a route
helper. Every server-side string the thread shows — the failure sentence, the
thinking line, the cap line, both speaker labels — and the endpoint, the turn
cap and the Explain button's fixed message are rendered as Stimulus values on
the wrapper. The repetition per section is the cost of the values being read
where they are used rather than from a global.

## Selecting one thread

The wrapper no longer carries `data-duck-thread` or `data-section`: the
controller name and its section value say both. A browser spec picks one
thread out with `.duck-thread[data-duck-thread-section-value='…']`.
