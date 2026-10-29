# app/prompts/generation_prompt/retry_reasons.rb

## `LINES`

One fixed line per recorded cause of a turned-down section (#610): the four judge principles from `JudgeVerdict::PRINCIPLES`, and every `<kind>.<check>` code a kind's `.reject_unusable!` refuses with (`ExerciseSection.refusal_codes`). The owner asked for a fixed line only, so a line never carries the judge's free-text `reason` or `evidence`, or any part of the rejected draft.

The judge lines restate the principle for the writer rather than copying `SectionJudgePrompt`'s definitions, which tell the judge when to reject. The two cap lines read their numbers from the kind's constant, so a cap change moves the line with it.

`generation_prompt_retry_reasons_spec` holds the keys to exactly the principles and refusal codes, so a new check or principle without a line fails, and keeps one snapshot per line in `spec/fixtures/retry_reason_snapshots/`.

## `.line`

Returns nil for a cause not in the table, and `GenerationPrompt#fixed_concept_line` then names no reason, so the prompt never claims a cause it doesn't have.
