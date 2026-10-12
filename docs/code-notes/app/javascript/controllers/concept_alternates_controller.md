# app/javascript/controllers/concept_alternates_controller.js

## What it owns

The "explain this differently" control inside a concept reference: the request,
the framings added to the page, and the cap.

## The cap is module-level, keyed by reference id

One reference can render several times on one page — every History entry
tagged with the same concept. All of those copies share one cap, so the
framings already shown live in a module-level `Map` keyed by the reference id
rather than on an instance. Nothing is persisted: a framing is gone on reload,
which is the feature's design.

## Peers are found by the Stimulus attribute

Stimulus renames a value attribute, so peer copies are found by
`data-concept-alternates-reference-id-value`. The pre-Stimulus `data-reference-id`
selector would match nothing and silently break the shared cap.

## Order inside addFraming

The status line is set and never cleared: the framing itself lands outside the
live region, so clearing the status would announce nothing. Focus moves to the
new paragraph before the buttons are removed, because removing the focused
button drops focus to the body.
