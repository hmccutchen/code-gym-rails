# app/javascript/controllers/pseudocode_round_controller.js

## What it owns

The one-shot critique round under a pseudocode section: the button, the status
line and the panel the provider's reply renders into.

## Rendering is textContent only

The reply is provider output. It is written with `textContent`, never
`innerHTML`, so nothing in it can become markup. The heading is created as its
own element rather than interpolated.

## The button re-enables only on failure

A successful round consumes the section's single critique, so the button goes
and stays away. A failed one consumed nothing, so the button comes back and the
engineer can try again. A 409 `stale` refusal is the exception: a retry from
this page would only be refused again, so the button stays disabled, the
status line shows the refresh text, and the controller sends
`code-gym:stale-save` with the reply's `banner:`, so `fresh_day_controller`
shows the out-of-date banner when it is already up or something on the page is
unsaved, as it does for a refused autosave.

## The draft scope

The critique posts the answer form's draft scope, read from the nearest
`data-answer-form-draft-scope-value` as the duck does. The server refuses a
missing or mismatched scope with a 409 before it creates, claims or sends
anything, and a not-current refusal uses it to pick the banner sentence for
the set the page shows (`CurrentSetLookup#posted_draft_scope`).
