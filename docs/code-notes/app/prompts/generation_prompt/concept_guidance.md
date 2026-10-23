# app/prompts/generation_prompt/concept_guidance.rb

## The module

One private method per concept group that needs a cross-section rule, each
named from its `ConceptVocabulary` constant and stated once for every section.
`GenerationPrompt` includes the module and interpolates each method once, so
`ai_service_spec` can assert that each group's instruction occurs exactly once
in the rendered prompt. A new group adds a method here and one interpolation
in `GenerationPrompt#render`.

## `#data_modeling_idiom_guidance`

Defers to each section's own vocabulary because ingest validates against the
full vocabulary and would not catch a misuse.

## `#oo_design_violation_guidance`, `#module_design_depth_guidance`, `#domain_modeling_guidance`

Like `#meta_skill_framing_guidance`, each keeps a findable issue in the
section: the principle frames the question and never replaces the issue, since
interface depth or a judgment about the model can otherwise leave nothing
missable to grade.

## `#silent_correctness_guidance`

The opposite risk to the other groups: the planted code must look like it
works, or the concept is no longer what its name says.
