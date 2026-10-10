# spec/services/problem_set_ingest_spec.rb

## "keeps a valid ambiguity_hunt concept regardless of the day's language"

The fixture carries a usable `planted_ambiguities` list because, through `.call`, an `ambiguity_hunt` without one is refused before its concept is ever checked.

## "drops an unusable diagram instead of persisting it"

An over-long diagram is dropped rather than truncated: half a diagram is broken Mermaid, which the renderer would reject anyway.
