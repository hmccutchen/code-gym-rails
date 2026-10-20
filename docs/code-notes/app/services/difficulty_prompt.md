# `DifficultyPrompt`

The post-review difficulty assessment's prompt, moved out of `AiService` (#431). `AiService#assess_difficulty` still makes the call and keeps only usable levels. Its token cap and the grace period `ReviewGrading` waits for it stay on `AiService`, since they are call settings.

## `.generate`

It takes the coach and each section's data, and renders each section only through `SectionContext.render`. It never takes the response, the answers, the ratings or any history, so the rating cannot read out a mastery tier.

## `GUIDANCE`

Keyed by level from `DailyResponse` so the labels can't shift. A spec, not the
`KeyError`, catches a missing level.
