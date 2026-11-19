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
engineer can try again.

## The draft scope

The critique posts the answer form's draft scope, read from the nearest
`data-answer-form-draft-scope-value` as the duck does, so a not-current
refusal can carry the banner sentence for the set the page shows
(`CurrentSetLookup#posted_draft_scope`).
