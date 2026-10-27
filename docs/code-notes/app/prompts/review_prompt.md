# `ReviewPrompt`

The two-stage review's text, moved out of `AiService` (#431). `AiService#build_review_day_context` and `#build_review_section_prompt` still gather each section's values from the exercise and the response. `ReviewGrading` takes the day context as a callable, and `#grade_review` makes each call and stamps `ReviewedSectionResults::RUBRIC_VERSION`. The stamp lives with the evidence rules rather than here, since the competency gate and level suggestions read it through `ReviewedSectionResults` and raising it is a decision about evidence, not about wording.

## `.section_prompt`

It takes the rung as a value. `AiService#review_rung` chooses it: the section's stamped `pitched_at`, or else the user's current rung, which reads `KindDifficulty` for the user and so cannot happen in a prompt class.

## `RATING_RUBRIC`

Stated once, in the day-level system prompt, so the section prompts never repeat it and the grader reads one definition of the four ratings.

## `.walkthrough_prompt`

It shares the entry rules and the JSON header with `.section_prompt` but leaves out the per-kind grading note on purpose: a grading note brings grading instructions into a prompt that must request no grade. It never asks for "rating" or "essential_gaps". When the engineer wrote something too short to count, it says so and does not call the section blank.
