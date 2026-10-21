# `ExerciseDraft`

Moved out of `AiService` (#431). It drafts a day's set and retries one
section, reaching the provider only through `ExerciseDraft::Provider`, so its
specs drive it with lambdas. The draft carries its user and language, so a
retry needs only the draft, the kind and the concept.

## `.call`

`LanguagePrompts.for` runs first. Planning reads `ConceptVocabulary`, which
raises its own unknown-language error, so checking first makes an unsupported
language fail as `SetupError` before any planning work.
`ConceptVocabulary::UnknownLanguage` is a `SetupError` too, so the check
changes when the failure happens, not how it's classified.

History is fetched once and handed to the prompt as a whole value, so the
logged "requested" history can't diverge from what the prompt contained.

## `.retry_section`

A retry renders from the draft's own plan, history and difficulty with fresh
ladders for the retried kind, and stores nothing on the draft. It passes the
deadline less a judge's worst case, so its re-judge still has room.

## `.finish`

`draft` still holds every drafted section, so `GenerationDiagnostics#finished`
can name a dropped key with its concept. The logging itself, and its notes,
are in `docs/code-notes/app/services/generation_diagnostics.md`.

## `.record_suggested_concepts`

Rescued per suggestion, so one bad name can't discard the rest, and a failure
here never breaks generation. Each write goes through the provider's
`record_suggestion` callable, which is `AiService#record_suggested_concept`,
so a script's service subclass can override that method to keep a comparison
run from writing `SuggestedConcept` rows (`script/model_comparison.rb`,
`script/concept_reference_calibration.rb`).
