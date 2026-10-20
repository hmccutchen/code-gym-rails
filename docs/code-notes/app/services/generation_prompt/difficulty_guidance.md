# app/services/generation_prompt/difficulty_guidance.rb

## `.render`

The one renderer of the difficulty block. `GenerationPrompt#render`
interpolates it and `GenerationDiagnostics#kind_difficulty` measures its
`.length`, so the logged `kind_difficulty_chars` is the length of the text
that was sent, leading newline included.

Every kind on the plan is listed at its rung, the target when one is set and
the skill level otherwise. A kind renders the same either way, so a target
equal to the skill level changes nothing in the prompt, which
`level_suggestion_isolation_spec` pins: the junior track's presets can be
dropped without any account's prompt moving. Before 2026-10-15 the block listed
targeted kinds only, and an untargeted kind got nothing but the profile's
"Skill level" line.

## `.level_difficulty_paragraph`

A level with no ladder rungs still gets its definition, so a kind nobody
prepared ladders for is pitched by the level's own description rather than
left to the profile line.

## `.locked_difficulty_line`

An easing rule added to the prompt later must be added here on purpose;
nothing covers it by implication.
