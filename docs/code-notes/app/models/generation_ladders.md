# `GenerationLadders`

Moved out of `AiService` (#431).

## `.for`

Returns concept guidance keyed by the owning kind. The kind's
`difficulty_definition` supplies the effective reference rung; vocabulary
selection still receives the configured rung and the original gotcha and
featured-concept exclusions. A principal bug hunt reads senior text, while
an ordinary principal kind still reads principal text.

The renderer groups only equal effective rungs and deduplicates identical
concept/text pairs within that group. Keeping ownership until rendering
preserves two different effective-rung texts for a shared concept in the
generic no-pick API, regardless of input order. Normal picked-gotcha plans
still exclude that concept from every other kind.
