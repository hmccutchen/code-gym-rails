# `ReviewPrompt`

The two-stage review's text, moved out of `AiService` (#431). `AiService#build_review_day_context` and `#build_review_section_prompt` still gather each section's values from the exercise and the response. `ReviewGrading` takes the day context as a callable, and `#grade_review` makes each call and stamps `ReviewedSectionResults::RUBRIC_VERSION`. The stamp lives with the evidence rules rather than here, since the competency gate and level suggestions read it through `ReviewedSectionResults` and raising it is a decision about evidence, not about wording.

## `.for_section`

The one place that chooses a section's review prompt: the graded prompt for an answered section, the walkthrough for an unanswered one. It takes `answered:` as a value rather than deciding from the answer text, since `DailyResponse#answered?` is the one authority on that and a prompt class reads no response (#583). An unanswered section's answer text is ignored.

## `.section_prompt`

It takes the rung as a value. `AiService#review_rung` chooses it: the section's stamped `pitched_at`, or else the user's current rung, which reads `KindDifficulty` for the user and so cannot happen in a prompt class.

## `RATING_RUBRIC`

Stated once, in the day-level system prompt, so the section prompts never repeat it and the grader reads one definition of the four ratings.

## `.walkthrough_prompt`

It shares the entry rules and the JSON header with `.section_prompt` but leaves out the per-kind grading note on purpose: a grading note brings grading instructions into a prompt that must request no grade. In its place it reads the kind's `walkthrough_note`, empty except for Parsons, which supplies the correct block order. It never asks for "rating" or "essential_gaps".

Both prompts end with the same fields, and the `improved_code` field line reads the kind's `.improved_code_instruction(section:, answered:)`. That hook is the one place a kind says what its improved code should hold, so the walkthrough gets it too. Before #642 pattern, plan review and pseudocode to code said it in their grading notes, which the walkthrough leaves out, so an unanswered section's improved code came with no instruction.
