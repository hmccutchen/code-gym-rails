# app/javascript/controllers/comparison_answer_controller.js

## What it owns

The design comparison's two visible controls — the A/B radios and the reason
textarea — and the hidden field that carries their combined value.

## Why a hidden field at all

The stored answer is one string, `pick:a` and a newline and the reason, so one
textarea has to hold both halves. `compose()` is the single writer, and it
dispatches a bubbling `input` event so `answer_form_controller` autosaves it
exactly as it autosaves a typed answer. Without that dispatch a programmatic
value change raises no event and the day would never save.

## `show()`

The reverse of `compose()`: it puts a hidden field's value back into the radios
and the reason. The answer form restores an unsent answer from the device into
the hidden field and fires `answer-form:restored`, which reaches `show()`
through the element's `data-action`. Stimulus binds that action only once this
controller connects, and the parent can restore first, so `connect()` also
calls `show()` when the hidden field no longer holds what the server rendered.
It writes no event, since the hidden field already holds the value.

## The data attributes the specs read

`data-comparison-answer` and `data-comparison-reason` stay on the markup. They
are not Stimulus targets — the targets carry their own names — but request and
system specs select on them, and they describe the field rather than the
wiring, so they outlive the conversion.
