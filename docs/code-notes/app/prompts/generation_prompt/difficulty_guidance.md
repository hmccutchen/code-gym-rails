# app/prompts/generation_prompt/difficulty_guidance.rb

## `.render`

The one renderer of the difficulty block. `GenerationPrompt#render`
interpolates it and `GenerationDiagnostics#kind_difficulty` measures its
`.length`, so the logged `kind_difficulty_chars` is the length of the text
that was sent, leading newline included. Both callers pass the plan's
code-review mode to the kinds' definition interface.

Every kind on the plan is listed at its rung, the target when one is set and
the skill level otherwise. A kind renders the same either way, so a target
equal to the skill level changes nothing in the prompt, which
`level_suggestion_isolation_spec` pins: the junior track's presets can be
dropped without any account's prompt moving. Before 2026-10-15 the block listed
targeted kinds only, and an untargeted kind got nothing but the profile's
"Skill level" line.

## `.level_difficulty_paragraph`

Each kind returns its composed `difficulty_definition`. Equal effective
rungs share a baseline within a configured level, followed by each kind's
expectation. A conditional heading names the owners of the concept guidance
directly below that baseline. Only identical concept/text pairs within the
group are deduplicated; different effective rungs keep separate lists.
Both baseline parts remain present without references. Kind-owned context
handles the bounded bug-hunt exception without a branch in this renderer.

## `.locked_difficulty_line`

An easing rule added to the prompt later must be added here on purpose;
nothing covers it by implication.
