# `ReviewProseJudgePrompt`

The prompt for the optional second pass that rewords a graded review's prose, moved out of `AiService` (#431). `AiService#judge_review_prose` still projects the review, makes the call and parses the verdict against that same projection. Its token cap and read timeout are call settings, in `CallProfiles`. `ReviewProseJudge` is the switch that decides whether the pass runs at all.

## `.generate`

It takes the kind, the coach and the projection, which is the review's prose fields only. It is never shown the answer, the problem, the grading note, the rating or the improved code. The text here is what `docs/decisions/review-prose-judge.md`'s activation gate measured, so a change to it has to pass that gate again.
