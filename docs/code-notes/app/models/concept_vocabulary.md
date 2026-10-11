# app/models/concept_vocabulary.rb

The closed concept lists a section can be tagged with, and the two questions
asked of them. They are domain data rather than provider data, so this module
never reads `AiService`; `AiService` keeps each language's prompt wording in
`LANGUAGE_PROMPTS`, and a spec holds its keys equal to `LANGUAGES`.

## `DATA_MODELING_CONCEPTS`

These sit in both language vocabularies because `ConceptBucket` dispatches on
section key, and a schema-review day's key is still `code_review`.

## `CODE_SMELL_CONCEPTS`

Named smells, not remedies. They are shared across languages because each one
means the same in a Rails class and in a React component.

## `OO_DESIGN_CONCEPTS`

Kept small on purpose: candidates that would generate the same section as an
existing concept were cut.

## `MODULE_DESIGN_CONCEPTS`

What an interface costs its callers. Candidates that duplicated
`shotgun_surgery` or `open_closed` were cut.

## `SILENT_CORRECTNESS_CONCEPTS`

Code that runs cleanly and is still wrong. These are remedies to reach for, so
they stay off `ANTI_SHAPE_CONCEPTS`.

## `DOMAIN_MODELING_CONCEPTS`

What a thing is called, and which writes change together. These are
disciplines, so they stay off both `ANTI_SHAPE_CONCEPTS` and
`TRADEOFF_CONCEPTS`.

## `COMPLEXITY_CAUSE_CONCEPTS`

Its own constant because `ANTI_SHAPE_CONCEPTS` names it before
`ARCHITECTURE_CONCEPTS` is defined.

## `ANTI_SHAPE_CONCEPTS`

Things to find, not to choose between. References are cached forever, so a
remedy framing applied to one of these would never correct itself.

## `RAILS_SECURITY_CONCEPTS`

`security_review` draws only from these, so each concept is practised both as
"is this correct" and as "is this exploitable".

## `TYPESCRIPT_FLAVORED_CONCEPTS`

TypeScript syntax is asked for only in a section tagged with one of these.
Other JavaScript concepts stay plain JavaScript.

## `GROUPS`

The order is the Learn index's display order, and `ConceptGroup::NAMED` is
derived from it, so a concept in two groups displays under the first.
`.excluded_concepts_for` reads the same table, so a kind can only exclude a
group listed here.

## `.for_section` and `.selectable_for_section`

Validation and generation use separate lookups. `parsons_problem` narrows its vocabulary without a mode, so a nil mode cannot tell the two uses apart.

`.selectable_for_section` always returns a subset of `.for_section`, so nothing it offers is rejected at ingest. Ask it, not `.for_section`, what may be requested.

## `.excluded_concepts_for`

`ExerciseSection.for` returns the base class for an unknown key, and the base class excludes nothing, so a provider-invented key excludes nothing rather than raising.
