# `SectionJudgePrompt`

The prompt for the judge that checks one generated section before an engineer sees it, moved out of `AiService` (#431). `AiService#judge_section` still makes the call, under the generation deadline, and parses the verdict through `JudgeVerdict.parse`. `CallProfiles::JUDGE_MAX_TOKENS` holds its token cap, as a call setting.

## `.generate`

It strips every answer-key field, every `ProblemSetIngest::SERVER_STAMPS` field and the kind's `.judge_hidden_fields` before rendering, so the judge sees one section as the engineer will, with no concept history. It returns the kind's verdict schema as `response_schema:`.

## `PRINCIPLE_GUIDANCE`

Fetched by name in `JudgeVerdict::PRINCIPLES`' order, so a new principle fails
loudly here instead of reaching the judge without guidance.

## `.guidance_block`

Stands in for the blank line above the section, so a kind with no judge
guidance renders its usual prompt.
