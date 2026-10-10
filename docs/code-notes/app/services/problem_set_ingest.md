# app/services/problem_set_ingest.rb

## `Suggestion`

`bucket` is the vocabulary bucket the off-list concept would have belonged to. `SuggestedConcept` records the suggestion under that bucket.

## `Unusable`

`concept` is nil when the refused section's tag is off-vocabulary, so a retry is only asked for a concept the plan could have placed.

## `.call`

It raises `AiService::InvalidResponseError` when the set cannot be used. A caller that passes no rungs (`pitched_at: nil`) gets no `pitched_at` or `eased` stamps.

## `.prune_to_expected_keys`

This only drops unexpected keys from a draft that has already been ingested. It works on a deep copy, so the draft the logs read stays intact.

## `#reject_missing_sections!`

A set missing an intended section is refused, because a short set would under-report `sections_total` and shrink tomorrow's set. Extra sections are fine.

## `#reject_unusable_sections!`

A refused section is removed on its own. The next shape in its slot then resolves and is checked in turn.

## `#normalize_diagrams!`

A diagram is rendered into an HTML data attribute, so it is held to `MermaidSource`. An unusable diagram is deleted rather than repaired.
