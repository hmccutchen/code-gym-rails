# `GenerationDiagnostics`

Moved out of `AiService` (#431). Each method writes log lines only; nothing it does changes what is generated.

## `#difficulty`

Difficulty adaptation is advisory. This line pairs what was requested with what
was delivered to check it, alongside `ResponseReview#log_diagnostics`.

## `#kind_difficulty`

Measures whether a rung was available and chosen. Whether the problem was
actually pitched at that rung is deliberately not measured.
`kind_difficulty_chars` is the length of
`GenerationPrompt::DifficultyGuidance.render`'s output, the same call the
prompt interpolates, so the logged count is the text that was sent.

## `#difficulty` and answer keys

Answer-key fields must never reach a log before review, and this line logs
the delivered set, so it logs `ExerciseSection.without_answer_keys` of it.
The redaction specs in `ai_service_spec.rb` cover it through the public
generation path.
