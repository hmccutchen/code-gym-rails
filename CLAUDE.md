# Code Gym Rails — Project Context for Claude Code

## What This Is

A team Rails app for daily personalized coding exercises. Each engineer logs in (magic link, no passwords), adds their own AI provider API key (Anthropic or Gemini), and gets an AI-generated problem set each morning tailored to their performance history. After submitting answers they can request an inline AI review, rate difficulty, and leave feedback — all of which feeds into the next day's problem generation.

## Git Workflow

All changes are made on a feature/dev branch, never directly on `main`. Create (or switch to) a branch before touching any files, and open a PR into `main` when the work is ready for review.

## Code Style

**Self-documenting.** The code says what it does; names carry the meaning. If a
block needs a comment to be followed, extract it into a named method instead.

**Comments are extremely minimal.** Write one only for a non-obvious *why* — a
hidden constraint, a workaround, an invariant a future reader would otherwise
break. Never restate *what* the code does. A comment that would go stale the
next time the line changes shouldn't be written. One that already has gone
stale is worse than either kind — fix it or delete it, don't leave it.

**Some comments must survive a cleanup.** The rule above cuts restatement, not
explanation, and a few categories read as obvious while carrying something the
code genuinely doesn't say. Keep: a non-RESTful route (`# GET /login` above
`SessionsController#new` — the path isn't derivable from the controller and
action), a partial's required locals, an abstract method's contract, and a
deliberately empty branch where the emptiness *is* the behavior (see
`User#current_streak`'s weekend case). The test runs both directions: if
deleting it would let someone reintroduce a bug, it stays; if it only repeats
the line beneath it, it goes.

When auditing comments mechanically, note that `#{...}` interpolations and `#`
lines *inside* a heredoc are content, not comments — in `AiService` they are
prompt text sent to the provider, and in `FakeService` canned provider output.

**Modular, so it's easy to change.** Following pragmatic-programming principles:

- **DRY** — every piece of knowledge has one authoritative home. When a rule
  starts appearing in a second place, move it to one place both call (see
  `DailyResponse.answered?`, `AiService`'s prompt/schema ownership).
- **Orthogonal** — a change in one area shouldn't ripple into unrelated ones.
  Provider specifics live in the `AiService` subclass, per-kind facts live in
  `ExerciseSection`, so adding a provider or a section kind means adding a
  class, not editing shared code.
- **Small, single-purpose units** — you should be able to say what a class or
  method does in one sentence. A file that keeps growing is doing too much.
- **Program to the interface** — callers depend on the shape a collaborator
  exposes, not its internals, so internals can be replaced without a rewrite.
- **Easy to change beats clever** — prefer the obvious implementation. Optimize
  for the next person changing it, not for line count.
- **Fail loudly at the boundary, degrade gracefully in the UI** — validate
  external input where it enters (provider output, params), and let anything
  downstream assume it's clean.
- **YAGNI** — build what's needed now. Don't add configuration, abstraction, or
  a table for a case that doesn't exist yet.

## Standards and Authorities

The principles above say what to aim for. This section says what this project
treats as authoritative when "well-tested standard" would otherwise be left to
interpretation.

**Style baseline: `rubocop-rails-omakase`.** `.rubocop.yml` inherits it whole
and overrides nothing. Where omakase has an opinion, that opinion wins — don't
argue formatting in review. Two things it deliberately does *not* cover, so
neither is machine-checkable here: `Metrics` and `Naming` are disabled outright
(no method-length, class-length, ABC, or complexity cop runs, and no naming cop
at all), and `Lint` is off except for three re-enabled cops.
`Lint/UselessAssignment` is not among them, so dead locals left behind by an
extraction are a known blind spot — grep for them yourself.

**Rails-native concerns follow Rails Guides conventions.** Validations,
callbacks, migrations, strong params, routing, and Active Record query
construction should look the way the Guides write them. Reach for a Rails
idiom before inventing one; if the Guides' way is wrong for a case here, say
why in the PR description rather than quietly diverging.

**Patterns this codebase has deliberately adopted.** These are settled
decisions, not defaults that drifted into place:

- **Template method for providers** — `AiService` owns prompts, vocabularies,
  parsing, and usage logging; subclasses implement only `#call` and
  `#build_connection`. Adding a provider is adding a subclass.
- **Registry for section kinds** — `ExerciseSection` and its subclasses answer
  every per-kind question (which are thirds, which scaffold, what the prompt
  says). Adding a kind is adding a class.
- **Pure decision objects** — `DailyPlan` decides the day's shape before any
  provider is contacted; `ProblemSetIngest` normalizes provider output and
  writes nothing, returning a `Result` instead. Both are pure, so their specs
  need no database. Keep them that way.
- **Single authority per fact** — `DailyExercise#active_section_keys` for how
  many sections a day has, `ConceptBucket` for which vocabulary a concept
  records under. Derive from the authority; never recount.

**Deviating from an established in-repo pattern requires stating why in the PR
description.** Deviation is allowed — patterns outlive their reasons sometimes
— but silent deviation is not. An unexplained departure is treated as an
oversight and blocks review.

### Rules that block review

These are enforced at review time (see `.github/copilot-instructions.md` for
the full checklist), and they are here so they shape code as it is written
rather than only catching it afterward:

- No branch on section kind, provider, or concept bucket in shared code — that
  is what the kind/provider class is for.
- No rule stated in two places that can disagree.
- No denominator, count, or threshold hardcoded where an authority computes it.
- No provider-facing input read without boundary validation in
  `ProblemSetIngest`.
- No new behavior without a test; no assertion weakened to make one pass.
- No comment left false by the change that touched it.
- New methods stay under 25 lines (excluding heredoc bodies), new `app/` files
  under 300 — or the PR says why not. Nothing enforces this mechanically;
  `Metrics` is disabled.

**What CI does and doesn't tell you.** The workflow runs RSpec, system specs,
RuboCop, Brakeman, and `importmap audit`. It does *not* run a Ruby dependency
CVE audit (`bundle-audit` is not installed) or any complexity check, and this
repository has no branch protection — so no check gates a merge. CI is
advisory signal; it is not evidence that anything was verified.

## Stack

- **Rails 8.0.5** + PostgreSQL
- **Solid Queue** — background jobs + recurring 8am weekday cron (no Redis needed)
- **Solid Cable / ActionCable** — mounted but unused; the dashboard learns generation is done by polling `GET /dashboard/status`, since this app's layout never loads Turbo JS
- **Faraday** — provider API calls (not the official SDKs)
- **BCrypt** — magic link token digests
- **ActiveRecord Encryption** — encrypts each user's provider API key at rest
- **Railway** — hosting (web + worker services, postgres service)
- **Nixpacks** — auto-detected build from `railway.toml`

## Architecture

```
User logs in (magic link email)
  └→ enters their own Anthropic or Gemini API key (stored encrypted per-user;
     the key's prefix determines user.provider)

8am weekdays (Solid Queue cron via config/recurring.yml):
  GenerateDailyExercisesJob
    └→ AiService.for(user) → ClaudeService | GeminiService
         reads: user.recent_performance (last 10 sessions + ratings + feedback + concepts)
         calls: the user's provider with a personalized prompt, in the user's
                chosen language (user.language_for_today)
         saves: DailyExercise { problem_set: jsonb, language } on success, or
         persists last_generation_error(_date) on the user on failure — the
         dashboard learns the outcome by polling GET /dashboard/status and
         reloading (this app loads no Turbo/Stimulus JS, so a live push has
         no subscriber)

User opens dashboard:
  └→ DashboardController#show
       shows today's DailyExercise, or triggers on-demand generation if missing
       (weekdays only; weekends offer a manual "generate anyway" button)
       4 sections: Code Review snippet, Pattern of the Month, a rotating third
       (Coding Challenge / Architecture Decision / Security Review / Parsons
       Problem), and a rotating fourth (Plan Review / Ambiguity Hunt)

User interacts:
  └→ ResponsesController#create      → auto-saves answers + difficulty rating +
       feedback text in one debounced fetch (idempotent). The rating renders at
       the end of the problem set and gates the Submit button — a set cannot be
       submitted unrated. Final submit returns to the dashboard.
  └→ ResponsesController#review      → AiService#review_response → ai_review saved,
       then redirects to /history anchored at that day. Synchronous; the button
       disables and relabels while it runs. Still manual/on-demand.
  └→ ResponsesController#email_review→ mails the completed review to the user,
       then returns to the dashboard (where the button lives)
  └→ DailyExercisesController#regenerate → replaces today's set in place (once/day)
  └→ HistoryController#index         → every submitted session, newest first,
       paginated 10 per page (pagy, offset) —
       the single destination for viewing any day's problems, answers, and
       review, today's included. There is no per-day review page.
       (feedback + concept tags are included in tomorrow's generation prompt)
  └→ AccountsController#show/destroy  → log out, or permanently delete (anonymize)
       the account in place while preserving all exercise/response/usage history
```

## Models

| Model             | Key fields                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| `User`          | email, name, skill_level, focus_areas (jsonb), api_key (encrypted), provider, language, anonymized_at (nullable — set on self-service deletion) |
| `DailyExercise` | user_id, date, problem_set (jsonb: code_review, pattern, a rotating third key, a rotating fourth key), language, generated_at, regenerated_at |
| `DailyResponse` | user_id, daily_exercise_id, answers (jsonb), rating enum, feedback_text, ai_review (jsonb), concept_tags (jsonb) |
| `ApiUsage`      | user_id, tokens_in, tokens_out, purpose, date                                                             |

## Key Design Decisions

- **Per-user API keys**: Each user provides their own Anthropic or Gemini key. Zero shared cost. The key's prefix (`sk-ant-` vs `AIza`/`AQ.`) selects `user.provider`; `AiService.for(user)` dispatches to the right subclass. Stored encrypted with `encrypts :api_key` (ActiveRecord Encryption) in the `users.api_key` column. The `ACTIVE_RECORD_ENCRYPTION_*` env vars are wired in via `config/initializers/active_record_encryption.rb` (Rails does not read them from ENV on its own); development derives throwaway keys from `secret_key_base` automatically.
- **Provider abstraction**: `AiService` is a template-method base class owning prompts, concept vocabularies, JSON parsing, and usage logging. Subclasses implement only `#call` and `#build_connection`. Adding a provider means adding a subclass, not editing the base.
- **Magic link auth**: No passwords. `User#generate_login_token!` creates a BCrypt digest, emails a token, `User#find_by_login_token` does constant-time compare. Tokens expire in 15 minutes.
- **JSONB problem sets**: `problem_set` column stores `{ code_review: {...}, pattern: {...}, challenge: {...} }`. Accessed via convenience methods on `DailyExercise`.
- **Closed concept vocabulary**: each section is tagged with one concept from a fixed per-language list (`AiService::RAILS_CONCEPTS` / `JS_CONCEPTS`), narrowed further at generation time for a schema-review `code_review` day (see below); anything a provider invents is normalized to `"other"` so concept history stays aggregatable.
- **`code_review` content modes**: `code_review` rolls one of three content modes per day (`DailyPlan::CODE_REVIEW_MODE_WEIGHTS`, roughly even) — `application_code` (realistic snippet, unchanged from before modes existed), `test_file` (a realistic test file exhibiting one test smell, in the day's `test_framework`), or `schema_review` (the day's `schema_artifact` — a Rails migration or a Prisma schema change with its migration — carrying one planted data-modeling flaw). Only `schema_review` narrows the vocabulary, to `AiService::DATA_MODELING_CONCEPTS` (`ProblemSetIngest.code_review_vocabulary`); the other two modes get the full list minus those concepts, unchanged from before modes existed. `pattern` and the rotating third deliberately keep the full vocabulary regardless of the day's `code_review` mode, so a due data-modeling retention check always has somewhere to land even on a non-schema-review day. Because that lets a data-modeling concept surface where no schema artifact is shown, `AiService#data_modeling_idiom_guidance` adds one prompt line — stated once for all sections, named from the constant — telling the model to express such a concept in the host section's own idiom (a `pattern` question about `wrong_cardinality` asks how the relationship should be modeled, not for a migration to review). Advisory prompt text, no new machinery; `[retention]` logs are the check on whether it lands.
- **The fourth slot**: a permanent fourth `problem_set` key, alongside `code_review`/`pattern`/the rotating third. Rotates 50/50 between `plan_review` (review a flawed implementation plan) and `ambiguity_hunt` (list what needs clarifying about a vague feature request). Each has its own closed vocabulary (`AiService::PLAN_REVIEW_CONCEPTS` / `AMBIGUITY_HUNT_CONCEPTS`) and its own `ConceptBucket` — language-independent, like `architecture`, so its mastery/reinforcement history never mixes with a programming-language bucket. `DailyPlan#for` decides the fourth slot's kind and its reinforcement/retention state on a track fully independent of the three-slot one, since the vocabularies can never mix. The slot holds exactly one concept (`DailyPlan::FOURTH_SLOT_CAPACITY`), so reinforcement is truncated to one and gives the slot up entirely when an overdue retention check claims it — never both. `ambiguity_hunt` also returns a hidden `planted_ambiguities` list — the answer key for grading coverage — which must never reach the rendered page, a pre-submission AI context (e.g. the duck thread), or log storage (`AiService#without_answer_key` strips it from the difficulty-diagnostics payload, the one place a whole `problem_set` is serialized); `plan_review`/`ambiguity_hunt`'s `plan_excerpt`/`request` fields are visible on screen and so are safe to include there. Since coverage grading has no meaning without that list, `ProblemSetIngest#reject_unusable_answer_key!` validates it at the provider boundary and raises `InvalidResponseError` when no usable entry came back — but only when `ambiguity_hunt` actually won the fourth slot, since an answer key nothing downstream will read is no reason to discard the day's other sections — the one normalizer that can refuse rather than repair. A *wrong count* is not a failure: `ExerciseSection::AmbiguityHunt::PLANTED_COUNT` is the generator's target, but nothing downstream reads it (the review prompt lists the ambiguities, never counts them), so a short list still grades and rejecting it would discard the day's other three sections over the likeliest deviation an LLM makes on a counted list. Long lists are truncated to `ExerciseSection::AmbiguityHunt::MAX_PLANTED`.
- **Which sections count**: `DailyExercise#active_section_keys` — the two fixed kinds plus the precedence-resolved third and fourth — is the single authority for "how many sections does this day have." Every denominator (progress bar, `completeness`, history's count, the generation prompt's history line), the numerator (`DailyResponse#answered_sections`, via `DailyResponse#section_keys`), the submit gate, the answer/rating param slices, the duck-thread section guard, and the review fan-out derive from it. Never `problem_set.keys`, and never `answers.keys`: a payload can hold more third- or fourth-shaped keys than the page renders (`FakeService` holds all eight deliberately, and a provider can return an extra alternate), and a regenerated day can leave an answer behind for a section it no longer presents — counting either reports a section count the page never showed.
- **Personalization loop**: `user.recent_performance(limit: 10)` returns the last 10 sessions with dates, sections answered, ratings, concept tags, and feedback text. This is embedded verbatim in the generation prompt so each day's exercises adjust to the user's trajectory.
- **One "answered" rule**: a section counts as answered when its text — minus any scaffold label lines the user never typed into — exceeds 10 characters. `DailyResponse.answered?` is the single source of truth: the progress bar, the teaching-hint lock, history, and the generation prompt all derive from it (the dashboard's inline script reads `ANSWER_MIN_LENGTH` and the labels from the server rather than restating the rule).
- **Answer scaffolds**: `pattern` and `architecture` ask for multi-part reasoning, so the generator returns an `answer_scaffold` — a short list of labels written for that specific question — inside the section's `problem_set` entry. A fresh textarea starts pre-filled with them; they are plain text in the same plain-string answer, so the user can delete or ignore them. Bounded on ingest (`ExerciseSection::MAX_SCAFFOLD_LABELS` / `MAX_SCAFFOLD_LABEL_LENGTH`) since it is provider output rendered into a form, and absent/unusable values fall back to the kind's `DEFAULT_SCAFFOLD`, so pre-scaffold rows render identically. `ResponsesController` normalizes on write: an answer that is nothing but labels stores as `""`, so every `answers[section].presence` reader — review prompt, history, `recent_performance` — sees what it saw before scaffolds existed.
- **One finish action**: the difficulty rating lives at the end of the problem set and autosaves on click, which enables the Submit button — disabled, with a visible nudge, until a rating exists. Answers and rating land in one `ResponsesController#create` call. The AI review stays a separate, manual step afterward — cost-conscious by design. A rating is set-only: `#create` assigns it only on a valid enum value, so a stale autosave can never clear one. The dashboard requires JavaScript; rating, autosave, progress, and submit are all driven by the inline script, and there is no server-side rejection of an unrated submit because the UI cannot produce one.
- **Idempotent saves**: `ResponsesController#create` uses `find_or_initialize_by(daily_exercise:, date:)` so auto-saves never create duplicates.
- **Preview apps**: a Railway PR environment starts with an empty database, so `PreviewSeed` (`app/services/preview_seed.rb`) seeds three days of demo content for the single account named by `PREVIEW_SEED_EMAIL`. It runs from `preDeployCommand` in every environment including production, and is safe there because it no-ops without that variable, only ever creates rows (never updates or deletes), and never reassigns a non-blank attribute. `PreviewMail` additionally sends mail inline when the variable is set, so magic-link login does not depend on the worker service. **`PREVIEW_SEED_EMAIL` must be set on the PR-environment template only** — set at the shared or base level, Railway propagates it into production. There is no login bypass: PR apps authenticate with real magic links.
- **Paginated history**: `/history` renders 10 submitted sessions per page via
  Pagy's offset paginator (`DailyResponse::HISTORY_PAGE_SIZE`). Pagy 43's API
  is a full rewrite — `Pagy::Method`, `pagy(:offset, …)`, and helper methods on
  the pagy object; the `Pagy::Backend`/`pagy_nav` API in most documentation is
  gone. An out-of-range page raises and redirects to the last real page rather
  than rendering the empty state to someone who has sessions. The post-review
  redirect uses `DailyResponse#history_page` so its anchor still resolves.
- **Parsons input**: drag (SortableJS, CDN) is the primary reorder mechanism;
  up/down arrow buttons are injected by script only if that import fails or
  stalls for 3s. Because dragging is pointer-only, every block is focusable and
  reorderable with Ctrl+↑/↓ (bare ↑/↓ moves focus), with an `aria-live` status
  line announcing each move — that keyboard path, not the arrows, is what keeps
  the section answerable without a mouse.

## Railway Deployment

- Project: `zesty-enthusiasm` (ID: `5b53ac62-bdb2-4e8d-a7f2-7a457b06ba4e`)
- Web service: `web-production-246e40.up.railway.app`
- Services: web, worker, postgres
- Web start command: `bundle exec puma -C config/puma.rb` (set in `railway.toml`; don't use `rails server -p $PORT` — Railway start commands run in exec form, so `$PORT` is never shell-expanded, while puma reads `PORT` from ENV)
- Worker start command: `bundle exec rake solid_queue:start` (set in `railway.worker.toml`; the worker service's Settings → Config-as-code file path must point at `/railway.worker.toml`, otherwise it inherits the web config and fails healthchecks)
- Env vars already set in Railway: `RAILS_ENV`, `RAILS_MASTER_KEY`, all three `ACTIVE_RECORD_ENCRYPTION_*` keys, `DATABASE_URL` (references postgres service)

## What Still Needs Work
1. ~~Email (magic links won't work yet)~~ — production delivers via Resend's HTTP API (`delivery_method = :resend`; Railway blocks SMTP below Pro). Needs `RESEND_API_KEY`, `MAIL_FROM`, `APP_HOST` on both Railway services: see `docs/deploy/railway-smtp-setup.md`. Sending to teammates requires a verified domain in Resend.
2. ~~`config/environments/production.rb`~~ — done. Resend delivery, `default_url_options`, and `raise_delivery_errors` are wired up from `ENV`.
3. ~~`db:migrate` on Railway~~ — done. `railway.toml` now runs `bundle exec rails db:migrate` via `preDeployCommand` on every deploy, before the new version takes traffic.
4. **Seed a first user**: After deploy, run `rails console` on Railway and create the first user manually, then invite teammates.
5. ~~Remove `/test_login` after buying a domain~~ — done. The route, `SessionsController#test_login`, and `spec/requests/test_login_spec.rb` have been deleted; the `TEST_LOGIN_SECRET` env var can be unset on Railway if still present.

## Local Development

```bash
cp .env.example .env
# fill in DATABASE_URL, SECRET_KEY_BASE, and the ACTIVE_RECORD_ENCRYPTION_* keys
bundle install
rails db:create db:migrate
bin/dev  # starts web + solid_queue worker
```

In development, magic link emails open in the browser via `letter_opener` gem (no SMTP needed).

## Tests

RSpec (`spec/` — models, requests, services, jobs, mailers). Run with:

```bash
bundle exec rspec
```

`spec/system/` holds a small number of real-browser specs (Capybara +
capybara-playwright-driver) covering flows unit/request specs can't fully
verify — rating-gated submit, review loading state — driven exclusively
against a `FakeService` (`provider: "fake"`) test user, never a real API key.
`FakeService` returns every section kind at once rather than the three a real
provider is asked for, so system specs can't assert which third `DailyPlan`
chose — cover that in service/job specs instead.
Running them locally requires a one-time Playwright CLI install — see the
comment block at the top of `spec/support/system_test_helper.rb` for the
exact commands. The npm manifests live in `spec/playwright/`, not the repo
root, so Nixpacks doesn't add a Node phase to the Railway production build.
CI runs system specs in a separate `system_test` job that installs the same
CLI (cached on `spec/playwright/package-lock.json`), while the `test` job runs
everything else via `--exclude-pattern "system/**/*_spec.rb"` — the two halves
run in parallel so unit/request feedback isn't gated behind browser setup.

CI runs the suite against postgres 16 on every PR (see `.github/workflows/ci.yml`).

## File Map

- `app/services/ai_service.rb` — provider-agnostic base: prompts, concept vocabularies, JSON parsing, usage logging
- `app/services/problem_set_ingest.rb` — the generation boundary: holds concepts to their closed vocabulary, bounds scaffolds and diagrams, rolls the parsons scramble, and rejects an unusable ambiguity-hunt answer key. Writes nothing — off-vocabulary concepts come back on the `Result` for `AiService` to record, so a rejected set structurally cannot leave a `SuggestedConcept` row behind. Pure, so its specs need no database.
- `app/services/daily_plan.rb` — the day's plan (third section, reinforcement, retention checks), decided before any provider is contacted; pure decision, no prompt or HTTP
- `app/models/concept_bucket.rb` — which vocabulary bucket a concept's history records under (architecture/plan_review/ambiguity_hunt are each language-independent; everything else buckets by the day's language)
- `app/models/exercise_section.rb` (+ `app/models/exercise_section/`) — the registry of section kinds (code_review, pattern, challenge, architecture, security_review, parsons_problem, plan_review, ambiguity_hunt); one class per kind answers which are thirds, which are fourths, which vocabulary they draw from, which show improved code, which scaffold their answer, and — via `.schema_fragment` / `.generation_guidance` — what the generation prompt says about them. `AiService` assembles those fragments and owns the language config; it no longer branches on section keys — or on kind identity — to build them. `.generation_guidance` takes a uniform context (`vocabulary:, label:, mode:, artifact:, test_framework:`) that every kind receives and each reads only its own part of; kinds that read none of the optional values absorb them with `**`. Adding a kind means adding a class here, not editing `AiService`.
- `app/helpers/answer_scaffolds_helper.rb` — the textarea pre-fill value and the `data-scaffold-labels` attribute the dashboard script reads, so the scaffold rule is stated once rather than per textarea
- `app/services/claude_service.rb` / `gemini_service.rb` — per-provider HTTP call + connection only
- `app/jobs/generate_daily_exercises_job.rb` — morning batch job + on-demand generation; persists failure state for the dashboard's status-polling to observe
- `app/controllers/responses_controller.rb` — auto-save (answers + rating), review, email-review endpoints
- `app/views/responses/_sections.html.erb` / `_section.html.erb` (+ `bodies/`, `answers/`) — the one loop over `DailyExercise#active_section_keys` and the one wrapper every section renders through, in both the answer-form and read-only states. Only the body and the answer area vary per kind, and each kind names its own partial for those (`ExerciseSection.body_partial` / `.answer_partial`), so adding a ninth kind is a body partial, an answer partial if it needs one, two `sections.<key>` locale strings, and whichever facets differ from the defaults — never a new branch in a template.
- `app/views/responses/_answered_sections.html.erb` — read-only render of a submitted day; shared by the dashboard's submitted state and every history entry. Its styles live in the layout's `<style>`, not a per-page block, precisely because it renders on both.
- `app/controllers/daily_exercises_controller.rb` — manual generate + once-daily regenerate
- `app/controllers/history_controller.rb` — paginated list of submitted sessions
- `app/controllers/sessions_controller.rb` — magic link create + verify
- `app/controllers/accounts_controller.rb` — Account page: log out + self-service deletion (anonymizes the user row in place)
- `app/models/user.rb` — auth methods, `recent_performance`, `language_for_today`, `anonymize!` / `active` scope, encryption
- `app/services/preview_seed.rb` — demo content for PR apps; create-only, gated on `PREVIEW_SEED_EMAIL`
- `app/services/preview_mail.rb` — inline mail delivery in preview apps, so login never needs a worker
- `app/services/fake_service.rb` — deterministic, zero-cost AiService provider for tests (`provider: "fake"`); overrides only `#call`/`#build_connection`, so every other AiService code path runs for real against its canned output. `AiService.for` refuses it outside a local environment.
- `spec/system/` — real-browser specs (Capybara + capybara-playwright-driver) against the fake provider; `spec/support/system_test_helper.rb` registers the driver
- `config/recurring.yml` — Solid Queue cron schedule (8am UTC weekdays)
- `railway.toml` — build + deploy config for Railway
