# `GenerationLadders`

Moved out of `AiService` (#431).

## `.for`

Reads the ladders of the user's own reference (`ConceptReference.indexed_for`).
A user whose row has no ladder gets none for that concept, whatever another
row holds. It reads nothing of
the user but the id, so `level_suggestion_isolation_spec` and
`trial_isolation_spec` hold.

Returns concept guidance keyed by the owning kind. The kind's
`difficulty_definition` supplies the effective reference rung; vocabulary
selection still receives the configured rung and the original gotcha and
featured-concept exclusions. A principal bug hunt reads senior text, while
an ordinary principal kind still reads principal text.

The renderer groups only equal effective rungs, collects the actual owners
of each exact concept/text pair, then gives entries with the same owners
one heading. A group's other kinds never inherit an entry they cannot
select. Keeping ownership until rendering
preserves two different effective-rung texts for a shared concept in the
generic no-pick API, regardless of input order. Normal picked-gotcha plans
still exclude that concept from every other kind.
