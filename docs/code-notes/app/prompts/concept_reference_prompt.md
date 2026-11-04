# `ConceptReferencePrompt`

The concept reference prompt and its reframe, moved out of `AiService` (#431). They are one family, since both work on the same reference and state the same `SCOPE`. `AiService#generate_concept_reference` and `#explain_concept_differently` still make the calls and check the replies.

## `.reframe`

It takes the fields already read as values, never the `ConceptReference` row, and no exercise or response, so it cannot see today's problem.

## `.senior_lens_description`

Shapes to find are never techniques to choose, so they skip the remedy lens;
design principles keep it.

## `.code_example_description`

`medium` is nil for a concept with no code of its own (see
`ConceptVocabulary.language_agnostic?`).

## `DATA_MODELING_NOTE`

The prompts name a concept only by its key and the coach's language, so in a
JavaScript prompt a model read `unsafe_migration` as React's `UNSAFE_`
lifecycle methods (#559). Every concept in
`ConceptVocabulary::DATA_MODELING_CONCEPTS` is about a database schema in
either stack, so the reference and reframe prompts say so for each of them,
appended to their first line. Other concepts get nothing appended, so their
prompts stay byte for byte as recorded. A stored row written before the note
keeps its text until it is regenerated.
