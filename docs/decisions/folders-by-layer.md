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
then adds the folders the preset doesn't know (`prompts`, `clients`, `forms`,
and `provider_registry`, which holds only `AiProvider`), lets controllers use
them, and keeps models, the registry, prompts, clients, jobs, mailers, forms
and helpers off the folders above them. A helper may read a client, because
`PushHelper` reads the public push key from `WebPushCredentials`.

Every component is also banned from `Thread`, from `send` and from
`ExerciseDraft.call`, and every component outside `app/clients` is banned
from `Faraday`. These replaced five checks in
`spec/conventions/app_source_spec.rb`: the thread, `send` and draft Prism
scans, the Faraday text match, and the scan for models naming a provider
class, which `models.cannot_use :clients` now covers. The new bans are
stricter than the scans: `Thread.current` fails as `Thread.new` did, and so
does a `send` whose argument is not a symbol.

`spec/conventions/archspec_rules_spec.rb` copies `app/` and `Archspec.rb`
into a temporary folder, plants a break in each component, and fails unless
archspec reports each one and nothing else. It also fails when a folder under
`app/` holds Ruby files and has no component, since a file in no component
escapes every ban.

These points about how the gem works shaped the file:

- A component is a real folder, never a catch-all such as "all of `app/`
  except one file". A class in several components is judged under all of
  them, which broke the preset's controller allowlist. `AiProvider` has a
  component of its own for the same reason: excluded from `models` and put in
  nothing, it escaped every ban. Leaving `models` also drops the preset's
  rules for it, so `Archspec.rb` states them again for the registry: no
  controllers or helpers, and no bare controller call, read from the preset's
  own `ArchSpec::Architectures::CONTROLLER_METHODS` so the two lists can't
  drift apart.
- A deliberate exception is an `archspec:disable-next-line` note on the line
  it excuses: the two `Thread.new` calls in `CallerZoneThread` and
  `CodeFormat::Javascript`, and the one `ExerciseDraft.call` in `AiService`.
  A note excuses one line, so a second thread on another line of an exempt
  file fails, which the old spec needed an exact per-file count to catch. A
  note names a rule, not a call, so the one on `AiService`'s draft line would
  also excuse a `send` added to that same line. Each note counts toward the
  file's five comments.
- Archspec merges the constant bans on a component into one rule, and the
  call bans that share a receiver into another. A rule carries one reason, so
  the `Thread` and `Faraday` ban shares its reason, while the `send` ban and
  the `ExerciseDraft` ban, whose receivers differ, keep their own.
- A bare call to a method a class defines or inherits is never flagged. A
  provider subclass calling `exercise_draft_provider` on itself would pass,
  so that one check stays a spec in `app_source_spec`, which fails on the
  name anywhere in `app/` outside `ai_service.rb`.

Other convention specs stay, because archspec sees only method calls and
named constants: a model taking `session` as an argument, a level write
spelled as an `update!` key, a `fetch` in JavaScript, and the isolation specs'
word matches such as `where(trial_ends_at: …)`.

The `:rails` preset has no loop check, so `Archspec.rb` adds `no_cycles`
among the preset's folders: controllers, models, helpers, mailers, jobs and
services. Jobs and controllers call services, so a service that reached back
into a job would close a loop. One did: `PracticeGeneration` included
`RecordsJudgeSolves` from `app/jobs/concerns`, which both generation jobs had
once shared. It was the concern's last caller, so the method moved into
`PracticeGeneration` and the concern was deleted (#751).

The check leaves out `clients`, `prompts`, `forms` and `provider_registry`.
Clients and services depend on each other on purpose: `AiService` hands
drafts and reviews to `ExerciseDraft`, `JudgedGeneration` and `ReviewGrading`
(the "provider calls as callables" pattern), and those services call
`AiService`.

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
