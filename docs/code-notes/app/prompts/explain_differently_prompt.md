# `ExplainDifferentlyPrompt`

The prompt that re-explains a reviewed section's missed points, moved out of `AiService` (#431). `AiService#explain_differently` still reads the review, makes the call and checks the reply. The concept reference's reframe is a different family and lives in `ConceptReferencePrompt`. The two share their wording through `PromptStandards`.

## `.generate`

It takes the question, the answer, the missed points and the earlier framings as values, never the exercise or the response, so what the prompt can see is exactly what its parameters list. `AiService` pulls those values from the reviewed section.
