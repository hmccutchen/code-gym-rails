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
