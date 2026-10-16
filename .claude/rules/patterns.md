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
  parsing and usage logging, and every prompt but the generation prompt, whose
  text it delegates to `GenerationPrompt` through its private
  `#generation_prompt` factory. `AiService#call(request)` is the template: it
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
- **One request value per provider call** — every provider call carries one
  `AiService::Request`: the purpose, the per-call values (system, prompt,
  history, response schema) and the settings (token cap, read timeout,
  caching, single attempt, allowed truncation). `AiService::CALL_PROFILES`
  is the one place a purpose's settings live. A call site builds its request
  with `AiService.request_for`, naming only its purpose and its per-call
  values, and hands it to `call_and_log(user, request)`. `Request.build`
  applies the defaults with no profile and takes any setting; tests and
  scripts use it when they need settings outside a profile, and `request_for`
  is its one caller under `app/`. A new setting is a field on `Request` and a
  key in the profiles that use it.
- **Registry for section kinds** — `ExerciseSection` and its subclasses answer
  every per-kind question (which are thirds, which scaffold, what the prompt
  says). Adding a kind is adding a class.
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
  section), `SharedConcept` (which concept both fixed sections take) and
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
  and `#review_grading_provider`). `AiService` keeps the calls and builds the prompts, the
  generation prompt through `GenerationPrompt`;
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
  stale may now belong to another caller. Anything that locks an exercise and
  its response goes through `DailyExercise#with_response_locked`.
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
  talking to a provider. Two exceptions still sit on `AiService`, and
  `GenerationPrompt` reads them there: `SCENARIO_POOLS` and the per-language
  prompt wording behind `.config_for`. Moving them to a domain module is a
  follow-up; the exception is recorded here so it is not read as the rule.
