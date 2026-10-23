# `FollowUpPrompt`

The prompt that answers a follow-up question about a reviewed section, moved out of `AiService` (#431). `AiService#answer_follow_up` still reads the review, makes the call and checks the reply. It is one of the two conversational calls, so it returns `history:` beside `system:` and `prompt:`.

## `.generate`

The engineer's own answer stays in the user turn, since a role boundary the
user can write across is no boundary.

The review summary reads only `DailyResponse::AI_REVIEW_FIELDS`, so the grader's original prose kept under `graded_prose` never reaches it.
