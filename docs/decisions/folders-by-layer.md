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

**The direction is enforced.** `archspec check`, which CI's lint job runs,
reads `Archspec.rb` and fails when a model or a prompt class references a
service or a client. `AiProvider` is excluded: it is the provider registry,
the one model that names provider classes. `archspec` is a development-only
gem, so it stays out of the production image, whose bundle skips only the
development group.

**Archspec holds the checks it can express.** `Archspec.rb` starts from
archspec's `architecture :rails` preset, as its getting-started guide
recommends. The preset keeps models and services off controllers and helpers,
and off a bare `render`, `params`, `session`, `cookies` or `flash`. The file
then adds the three folders the preset doesn't know (`prompts`, `clients`,
`forms`), lets controllers use them, and keeps models, prompts and clients off
the folders above them. Every folder is also banned from `Thread`, from
`send`, and from taking a draft (`ExerciseDraft.call`,
`#exercise_draft_provider`), and every folder outside `app/clients` is
banned from `Faraday`. These bans replaced four hand-written Prism scans in
`spec/conventions/app_source_spec.rb`.

Three points about how the gem works shaped the file:

- A component is a real folder, never a catch-all such as "all of `app/`
  except one file". A class in several components is judged under all of
  them, which broke the preset's controller allowlist.
- A deliberate exception is an `archspec:disable-next-line` note on the line
  it excuses: the two `Thread.new` calls in `CallerZoneThread` and
  `CodeFormat::Javascript`, and the one `ExerciseDraft.call` in `AiService`.
  A note excuses one line, so a second thread in an exempt file fails, which
  the old spec needed an exact per-file count to catch. Each note counts
  toward the file's five comments.
- Archspec merges every constant ban on a component into one rule, and every
  call ban into another, and a rule can carry only one reason, so each
  merged rule's reason covers all its bans.

Some convention specs stay, because archspec sees only method calls and named
constants: a model taking `session` as an argument, a level write spelled as
an `update!` key, a `fetch` in JavaScript, and the isolation specs' word
matches such as `where(trial_ends_at: …)`. The preset's loop check
(`no_cycles`) is left off, because `PracticeGeneration`, a service, includes
`RecordsJudgeSolves` from `app/jobs/concerns`.

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

**The isolation specs scan every layer below the views.**
`trial_isolation_spec`, `level_suggestion_isolation_spec`,
`duck_thread_isolation_spec` and `section_kind_guide_spec` used to scan
`app/{services,jobs}` plus a few named models, so a decision object moved to
`app/models` would have dropped out of them. They now scan every file under
`app/models`, `app/services`, `app/jobs`, `app/prompts` and `app/clients`
(`IsolationScope`, `spec/support/isolation_scope.rb`), less a short list of
owners each spec names: the classes that hold that state, and `User`. A new
model is scanned unless someone names it an owner.

**Excerpt rotation keeps its history.** `RealSource` excerpt ids are
`"<path>#<method>"`, and each day's code review stores the id it used
(`problem_set["code_review"]["source"]`), which `RealSource.pick` reads to
rotate excerpts. Seven excerpts point at files this move relocated, so their
ids changed. Read as they were stored, those seven would count as never used,
and `pick` would offer one ahead of excerpts a user really has not seen,
possibly the one from the day before. `RealSource.last_seen_for` therefore
matches each stored id to the current excerpt with the same file name and
method, and keeps the later date when both forms are present. That carries
history across this move and any later folder move without a table of old
ids. A spec holds file name plus method unique across the pool, which the
match depends on.
