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

Before planning it asks `FeaturedConcept.for(user)`, which can store the
week's pick, and passes its concept name to `DailyPlan.for(featured_concept:)`.
A database error from that lookup is logged and planning goes on with no
featured concept, since a missing exclusion costs one hidden-kind callout
mismatch the guards already cover, and a failed lookup should not stop the
day's set. The plan carries
it to the prompt, the ladders, the host checks and a retry, so all of them see
the same concept, and generation leaves it out of the sections that hide their
concept (#687). The lookup is here, in the service, so the pure plan reads no
table.

Assessed performance and delivered-content history are each fetched once.
The draft captures both whole projections and retries reuse them.
It also captures every kind's effective rung once, before the call, using
the captured difficulty, and retains the profile's baseline level. Initial
and retry prompts, ingest, ladders, the judge and requested diagnostics reuse
these captured values; judged notes persist the map as the period's input snapshot.
The map and its level strings are frozen independently of the user's fields.
Diagnostics log only assessed performance under `recent_performance`;
delivered scenarios are not added to logs.

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

## Key notes on a retry

`.retry_section` returns only the retried section, so it logs the ingest
result's key notes itself before returning. Otherwise a retried keyed
section would go missing from the `[planted_key]` lines the quote threshold
is counted from.
