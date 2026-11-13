# `ConceptReferencePrompt`

The concept reference prompt, its ladder-only prompt and its reframe, moved out of `AiService` (#431). They are one family, since all three work on the same reference. `AiService#generate_concept_reference`, `#generate_concept_ladder` and `#explain_concept_differently` still make the calls and check the replies.

## `.ladder` and `LADDER_INSTRUCTION`

`.ladder` asks for the four rungs of a concept that already has a reference
(#800). It takes the tagline and explanation as values, never the row, and no
exercise or response. They are context, so the rungs fit the text the person
reads. `LADDER_INSTRUCTION` is the rung instruction both `.generate` and
`.ladder` send, so the two ask for a ladder in the same words; `.generate`
renders it byte for byte as before it was shared, which its snapshots hold.

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
prompts stay byte for byte as recorded. A refresh never rewrites a fully
written row, so `DeleteJavascriptUnsafeMigrationReference` deletes the one
stored row known to teach the wrong thing; Learn's prepare button, or the next
submitted section tagged with the concept, writes it again with the note. The
other four JavaScript data-modeling rows were left: their names have no second
meaning in JavaScript, and the 2026-10-25 audit read `missing_index` as right.
