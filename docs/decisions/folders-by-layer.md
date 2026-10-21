# Folders by layer

`app/services` held 40 files, but only a handful orchestrated side effects.
About twenty were pure decisions (`DailyPlan`, `SectionCount`, `DaySize`,
`CompetencyGate`, `LevelSuggestion` and others), the prompt classes were pure
text builders, and the provider clients and other adapters sat beside them.
Models already called several of the decision objects, which read as a
domain-to-service dependency even though it was not one, and nothing stopped
a domain decision from starting to call a provider (#436).

**Each folder now names a layer.**

| Folder | Holds |
| --- | --- |
| `app/services` | classes that orchestrate side effects: `ResponseReview`, `JudgedGeneration`, `ReviewGrading`, `ExerciseDraft`, `GenerationDiagnostics`, `PushDelivery`, `PreviewSeed` |
| `app/models` | records and pure domain decisions, the moved decision objects included |
| `app/prompts` | the prompt classes, `PromptStandards` and `SectionContext` |
| `app/clients` | adapters to the outside: `AiService` and its provider subclasses, `WebPushCredentials`, `CodeFormat::Javascript` (Node), `SchemaWait`, `LazyCacheStore`, `CallerZoneThread`, and the environment switches `PreviewEnvironment`, `PreviewMail` and `ReviewProseJudge` |

The moves kept every constant's name: Rails autoloads each folder under
`app/` as a root, so `DailyPlan` is still `DailyPlan`. A namespaced domain
folder (`Planning::DailyPlan`) was turned down, because it would have renamed
every reference across the app, specs, scripts and docs for no change in
behaviour.

**The direction is enforced.** `Archspec.rb` declares the four folders as
components and fails `archspec check`, which CI's lint job runs, when a model
or a prompt class references a service or a client. `AiProvider` is excluded:
it is the provider registry, the one model that names provider classes.
`archspec` is a development-only gem, so it stays out of the production image,
whose bundle skips only the development group.

Archspec reads constants statically. `CodeFormat`, a model, picks its
formatter by name (`"CodeFormat::Javascript".constantize`), so that
dependency on a client is not seen. Formatting runs once, at ingest, and
never raises into it.

**The rubric stamp moved with it.** `ReviewedSectionResults` and
`CompetencyGate::Evidence`, now models, read `RUBRIC_VERSION`, which lived on
`AiService`. It moved to `ReviewedSectionResults::RUBRIC_VERSION`, beside the
rule for which reviewed sections count as evidence, and `AiService` writes
it. It did not move to `ReviewPrompt`: raising it is a decision about
evidence, not about the rubric's wording.

**The isolation specs scan the same files as before.** `trial_isolation_spec`,
`level_suggestion_isolation_spec`, `duck_thread_isolation_spec` and
`section_kind_guide_spec` used to scan `app/{services,jobs}`. They now scan
`IsolationScope` (`spec/support/isolation_scope.rb`): `app/services`,
`app/jobs`, `app/prompts`, `app/clients` and the decision objects that moved
to `app/models`, so a move out of `app/services` never shrinks what they
check.
