# `ReviewPrompt`

The two-stage review's text, moved out of `AiService` (#431). `AiService#build_review_day_context` and `#build_review_section_prompt` still gather each section's values from the exercise and the response. `ReviewGrading` takes the day context as a callable, and `#grade_review` makes each call and stamps `AiService::RUBRIC_VERSION`. The stamp stays on `AiService`, since the competency gate and level suggestions read it there and raising it is a decision about evidence, not about wording.

## `.section_prompt`

It takes the rung as a value. `AiService#review_rung` chooses it: the section's stamped `pitched_at`, or else the user's current rung, which reads `KindDifficulty` for the user and so cannot happen in a prompt class.

## `RATING_RUBRIC`

Stated once, in the day-level system prompt, so the section prompts never repeat it and the grader reads one definition of the four ratings.
