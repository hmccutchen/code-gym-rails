---
paths:
  - "app/**"
  - "lib/**"
  - "spec/**"
  - "config/**"
  - "script/**"
  - "db/**"
---

# Patterns this codebase has deliberately adopted

These are settled decisions, not defaults that drifted into place. CLAUDE.md
says what a deviation from one requires.

- **Template method for providers** — `AiService` owns provider orchestration,
  parsing and usage logging, and calls each prompt class for its text.
  `AiService#call(request)` is the template: it
  posts the body with the request's timeout and retry context, raises on a
  failed status, parses the reply and maps a Faraday error the same way for
  every provider. Subclasses implement `request_body`, `read_result`,
  `raise_for_status`, `provider_name` and `build_connection` behind it,
  define the `API_URL` it posts to, keep a private `route_for`, and own the model each purpose routes to
  (`DEFAULT_ROUTE` / `MODEL_FOR_PURPOSE`). A subclass overrides
  `long_running?` only when its retry rule differs, as `OpenaiService` does.
  Adding a provider is adding a subclass and listing it in `AiProvider.all`,
  the closed registry used by dispatch, key detection and user validation.
  Each subclass owns its `provider_key`, `key_pattern` and any environment
  restriction.
- **One class per prompt family** — prompt text moves out of `AiService` one
  family at a time (#431), into a class at `app/prompts/*_prompt.rb`; those
  files are the list of moved families, so no doc repeats it. A prompt class
  is pure: it takes values, never a record, a user or a database read, and
  returns the per-call keywords `AiService.request_for` takes (`system:` and
  `prompt:`, plus `history:` or `response_schema:` when the family has them).
  A family is the prompts about one subject, and one class may hold several
  purposes (the concept reference and its reframe are one family). The class
  holds its family's text and nothing else: settings stay in
  `CallProfiles::BY_PURPOSE`, and the call, the reply checks and the logging
  stay in `AiService`. That text includes a fixed message a page sends into the
  family's prompt, which the page reads from the class
  (`DuckPrompt::EXPLAIN_REQUEST`). A family built in two stages gets one
  method per stage, each returning that stage's string, such as the review's
  day-level system prompt and its per-section prompt. Text
  two or more families share lives in `PromptStandards`, and a section described
  for a prompt comes from `SectionContext.render`; a prompt class reads them
  there and never copies them. A prompt class is in the `paths:` of the area
  rule that states its isolation, so editing it loads that rule.
  `claude_rules_spec` fails on a prompt class that loads no area rule, but
  it cannot tell whether the rule is the right one, so the PR that moves a
  class names it. Each
  moved family's rendered text is pinned by `expect_prompt_snapshot`,
  recorded against the code before the move. `PseudocodePrompt` is the model;
  `GenerationPrompt` predates it, rendering the user prompt from an
  instance; its system prompt is the class method
  `GenerationPrompt.system_prompt`.
- **One request value per provider call** — every provider call carries one
  `AiService::Request`: the purpose, the per-call values (system, prompt,
  history, response schema) and the settings (token cap, read timeout,
  caching, single attempt, allowed truncation). `CallProfiles::BY_PURPOSE`
  is the one place a purpose's settings live. A call site builds its request
  with `AiService.request_for`, naming only its purpose and its per-call
  values, and hands it to `call_and_log(user, request)`. `Request.build`
  applies the defaults with no profile and takes any setting; tests and
  scripts use it when they need settings outside a profile, and `request_for`
  is its one caller under `app/`. A new setting is a field on `Request` and a
  key in the profiles that use it.
- **Registry for section kinds** — `ExerciseSection` and its subclasses answer
  every per-kind question (which are thirds, which scaffold, what the prompt
  says). Adding a kind is adding a class. Which kinds are daily is a per-user
  value (`DailyKinds`), so slot questions go through
  `ExerciseSection.layout(daily:)`.
- **Pure decision objects** — `DailyPlan` decides the day's shape before any
  provider is contacted; `ProblemSetIngest` normalizes provider output and
  writes nothing, returning a `Result` instead. `ProblemSetIngest` is pure, so
  its specs need no database; `DailyPlan` composes two pure collaborators of
  its own — `SectionCount` (how many sections recent completion allows) and `SectionRotation` (which
  kind fills each) — whose specs need none, even though `DailyPlan` itself
  reads concept-mastery history to decide reinforcement and retention. The
  same holds for `CompetencyGate` (how many sections reviewed work has
  earned), `DaySize` (the day's planned count from the setting, completion
  and the gate), `CoverageException` (whether a two-section day gains a
  section), `SharedConcept` (which concept both daily sections take) and
  `DayHosts` (which kinds can tag a concept today). Keep the collaborators
  that way.
- **Single authority per fact** — `DailyExercise#active_section_keys` for how
  many sections a day has, `ConceptVocabulary` for the concept lists and which
  of them a kind may be asked for, `ConceptBucket` for which vocabulary a
  concept records under. Derive from the authority; never recount.
- **One prompt line per vocabulary group** — a concept group that needs a
  cross-section rule gets one `GenerationPrompt::ConceptGuidance#<group>_guidance`
  method naming the group from its constant and stated once for all sections,
  never repeated into each kind's `.generation_guidance`. The rule is about
  the concept, not about any one kind, so every such group has exactly one of
  these methods and a new group adds another. Don't enumerate the groups here —
  the constants live in `ConceptVocabulary` and each group's guidance method in
  `GenerationPrompt::ConceptGuidance`, and a count kept in this file has
  already gone stale once.
- **Provider calls as callables** — a module that orchestrates provider calls
  takes them as a `Provider` struct of callables, with a `providers:` factory
  that returns a fresh one for each thread (`JudgedGeneration::Provider`,
  `ReviewGrading::Provider`, built by `AiService#judged_generation_provider`
  and `#review_grading_provider`). `ExerciseDraft` takes one
  `ExerciseDraft::Provider` (`AiService#exercise_draft_provider`), since a
  draft makes one call and a retry runs on the thread that asked for it. `AiService` keeps the calls and builds the prompts, or
  takes them from a prompt class;
  the module keeps the orchestration and the policy, and its specs drive it
  with lambdas. Threads start through `CallerZoneThread.start`, and
  `spec/conventions/app_source_spec.rb` fails on any other `Thread.new` and on
  `send(:...)` anywhere in `app/`.
- **Outcomes at the HTTP edge** — domain work an action triggers returns a
  value naming what happened (`ResponseReview::Outcome`, like
  `ProblemSetIngest::Result`), and the action only maps it to a redirect and a
  message, raising on a status it doesn't handle. Behavior specs drive the
  module; the request spec keeps one example per outcome.
- **Claims and lock order** — a timestamp column held as a lease on a paid
  call is declared with `Claimable` (`claim :name, column:, stale_after:`),
  released only with the token `#claim_<name>!` returned, and checked again
  under the row lock before anything is written, since a claim that went
  stale may now belong to another caller. The pseudocode critique claim is a
  key inside a JSON column, so it lives on `DailyResponse`
  (`#claim_pseudocode_critique!`) and keeps the same token rule under the row
  lock. Anything that locks an exercise and its response goes through
  `DailyExercise#with_response_locked`.
- **The server decides; the page shows its answer** — when a page needs a
  rule the server owns, the browser holds no copy of it. The server renders its
  answer onto the page and sends it again in every reply, and the script only
  displays the latest one (`answered_sections` and `submit_blocker` on the
  dashboard form and in each autosave reply).
- **Page behavior is a Stimulus controller** — a view carries markup and
  `data-action` attributes, never a `<script>` tag or an `on*` handler.
  `config/initializers/content_security_policy.rb` enforces it: a script runs
  only from this origin, from the two `cdn.jsdelivr.net` package directories
  the mermaid and Parsons controllers import, or under the nonce
  `javascript_importmap_tags` puts on its own tags, so an inline tag or
  handler is dead code. `spec/conventions/app_views_spec.rb` fails on either
  before CSP has to.
- **One way to send a request** — a page script sends through
  `CodeGymRequest.send`, and a save that must not overlap another goes
  through `CodeGymSaveStatus.queue`, never a hand-built `fetch` or its own
  promise chain. The server answers every error with `render_json_error`, so
  the browser has one rule for what a failure may show. A queue retries only
  when its caller passes `offline:` and only a save that got no reply; the
  dashboard's answers are the one caller, since its endpoint accepts a repeat.
- **Domain data stays off provider classes** — lists and tables the domain
  owns live in a module of their own (`ConceptVocabulary`), and `AiService`
  and `GenerationPrompt` read them; `AiService` keeps only what is about
  talking to a provider. A field list a model validates or checks lives on
  that model (`ConceptReference::GUIDE_FIELDS`, `RecognitionGuide::FIELDS`),
  and `AiService` reads it there. Each language's prompt wording is
  `LanguagePrompts` and the scenario settings are `ScenarioPools`, read by
  `AiService` and `GenerationPrompt`. Each purpose's call settings and the
  timing built from them are `CallProfiles`, which names no provider, so a
  model, view or job reads a worst-case call time there. `AiProvider`, the
  provider registry, is the one model that may name `AiService` or a provider
  class, for a provider's own quota day, and `app_source_spec` fails on any
  other model that names one.
- **Folders by layer** (`docs/decisions/folders-by-layer.md`) — a folder
  under `app/` says which layer its classes are in. `app/services` holds only
  classes that orchestrate side effects (a claim, a write, a provider call
  fanned out, a push). Pure decisions are in `app/models`, prompt classes in
  `app/prompts`, and adapters to the outside (the provider clients, push
  credentials, the Node formatter, environment switches, thread and cache
  helpers) in `app/clients`. Moving a file between them keeps its constant
  name. `Archspec.rb` fails CI when a model or prompt class references a
  service or a client; `AiProvider`, the provider registry, is the one
  exception. A new class goes in the folder for what it does, not next to
  the class that first calls it.
