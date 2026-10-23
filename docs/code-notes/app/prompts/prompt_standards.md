# `PromptStandards`

Prompt text that two or more prompt families read, moved out of `AiService` (#451) so a prompt class never reads its wording from `AiService`. Text only one family reads stays with that family, even when the family has several prompts: `ConceptReferencePrompt::SCOPE` is read by the concept reference and by its reframe, which are one family. That rule keeps this module from collecting every constant a prompt touches.

## `PLAIN_LANGUAGE_STANDARD`

The app's copy of CLAUDE.md's writing standard. `spec/prompts/prompt_standards_spec.rb` fails when the two drift apart.

## `.explain_differently_standard`

One rule shared by the concept reframe and the review-point reframe, so it cannot be edited in one without the other.

## `.prior_framings`

Each framing is fenced because the page sends them back, so a forged framing is
one request away. The concept reframe and the review-point reframe both send it.
