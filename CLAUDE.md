# Code Gym Rails — Project Context for Claude Code

## What This Is

A team Rails app for daily personalized coding exercises. Each engineer logs in (emailed 6-digit code, no passwords), adds their own AI provider API key (Anthropic, Gemini or OpenAI), and gets an AI-generated problem set each morning tailored to their performance history. They answer sections and rate difficulty before submitting. Submission requests an inline AI review; the submitted work and review feed into the next day's problem generation.

## Git Workflow

All changes are made on a feature/dev branch, never directly on `main`. Create (or switch to) a branch before touching any files, and open a PR into `main` when the work is ready for review.

## Code Style

### Comment rules — never ignored

These rules hold in every file, in every change, with no exceptions for a
deadline or a "temporary" comment. CI enforces the first three, so a
broken one fails the build: RuboCop in Ruby files, and `bin/comment-check` in
ERB (including its `<script>` and `<style>` blocks), JavaScript, CSS, YAML and
Python. The cop names below are the Ruby side.

- **Each comment is attached to the code it comments on.** It sits on the line
  directly above that code, or at the end of the same line. No blank line, no
  other comment and no end of file between a comment and its code
  (`CodeGym/AttachedComment`).
- **Each comment is one line** (`CodeGym/SingleLineComment`).
- **A file holds at most 5 comments in total**, trailing comments included
  (`CodeGym/CommentLimit`). Magic comments, shebangs and `rubocop:`
  directives are tooling and don't count, and neither does a bare route
  annotation (`# POST /responses/:id/review`, nothing else on the line), so
  every non-RESTful action keeps its path.
- **Code is self-documenting.** Names carry the meaning. If a block needs a
  comment to be followed, extract it into a named method instead.
- **Comments discuss the code in front of them.** Naming another place that
  has to change with this line is part of that; the design or history behind
  it belongs in the documentation.
- **Business decisions live in the documentation:** this file, or a doc under
  `docs/`. A design decision too long for this file's "Key Design Decisions"
  keeps a short entry there and its full text in `docs/decisions/`. The reasoning behind one file's code lives in
  `docs/code-notes/`, at the file's own path with `.md` in place of its last
  extension (`app/services/ai_service.rb` →
  `docs/code-notes/app/services/ai_service.md`;
  `app/views/layouts/application.html.erb` →
  `docs/code-notes/app/views/layouts/application.html.md`).
  A comment may point there in its one line.

**Comments are extremely minimal.** Write one only for a non-obvious *why* — a
hidden constraint, a workaround, an invariant a future reader would otherwise
break. Never restate *what* the code does. A comment that would go stale the
next time the line changes shouldn't be written. One that already has gone
stale is worse than either kind — fix it or delete it, don't leave it.

**Some comments must survive a cleanup**, within the five a file may hold
(route annotations don't count toward it). The
rule above cuts restatement, not explanation, and a few categories read as
obvious while carrying something the code genuinely doesn't say. Keep: a
non-RESTful route (`# GET /login` above `SessionsController#new` — the path
isn't derivable from the controller and action), a partial's required locals,
an abstract method's contract, and a
deliberately empty branch where the emptiness *is* the behavior (see
`User#current_streak`'s weekend case). The test runs both directions: if
deleting it would let someone reintroduce a bug, it stays; if it only repeats
the line beneath it, it goes.

When auditing comments mechanically, note that `#{...}` interpolations and `#`
lines *inside* a heredoc are content, not comments — in `AiService` they are
prompt text sent to the provider, and in `FakeService` canned provider output.

**Writing style.** Commit messages, PR descriptions, code comments, and any
technical explanation written for a person — a code review, a design note, a
debugging write-up, an answer to a question — follow the same plain-language
standard the app asks its own generated prose to meet.
The app's copy is `AiService::PLAIN_LANGUAGE_STANDARD`, shared by the prompts
that explain, reframe, answer follow-ups on, or grade an engineer's work.
`spec/services/ai_service_spec.rb` fails when the list below drifts from it.

Avoid, in order of how often these actually show up:

- Manufactured rhetorical contrast — "not X, but Y" used purely for punch when
  a plain sentence says the same thing.
- Buzzwords and jargon. Use the plain-language equivalent; if a technical term
  is genuinely necessary, define it briefly on first use.
- Placeholder phrases — "please note," "at this time," "it's worth mentioning."
- Overusing "please" in instructions — state it directly.
- Starting every sentence with the same construction.
- Exclamation points, outside genuine, rare emphasis.
- Forced cleverness or trying to sound entertaining.
- Both choppy fragments and long-winded run-ons.

Aim for:

- Active voice — make clear who or what is doing the thing.
- Concrete over abstract — a specific example beats a general description of
  the same idea.
- Conditions before instructions, not after.
- Natural rhythm — if a sentence sounds stilted read aloud, rewrite it.

The app's version also asks for second person, direct address. That item is
left off the list on purpose, because it depends on who is reading: an
explanation written for someone should use it, while a commit message or a code
comment has no reader to address.

Calibration: too informal ("This is a total game-changer!") and too
formal/overwrought ("The interface undergoes a paradigmatic transformation")
are both wrong; aim for the plain middle ("This changes how the interface
works").

Some developers also install a personal skill carrying this standard for prose
written outside any repository
(`~/.claude/skills/plain-communication-style/SKILL.md`). It is per-developer and
not part of this project, so nothing here depends on it — this section is the
whole rule for anything written into this repository, and it is the one with a
spec behind it if the two ever disagree.

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
and adds three house cops in `lib/rubocop/cop/code_gym/`, the comment rules
above (`SingleLineComment`, `AttachedComment`, `CommentLimit`). Where omakase
has an opinion, that opinion wins — don't argue formatting in review.
Two things it deliberately does *not* cover, so neither is machine-checkable
here: `Metrics` and `Naming` are disabled outright
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

- **Template method for providers** — `AiService` owns prompts, parsing, and
  usage logging; subclasses implement `#call` and
  `#build_connection`, and own the model each purpose routes to
  (`DEFAULT_ROUTE` / `MODEL_FOR_PURPOSE`). Adding a provider is adding a
  subclass and listing it in `AiProvider.all`, the closed registry used by
  dispatch, key detection and user validation. Each subclass owns its
  `provider_key`, `key_pattern` and any environment restriction.
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
  cross-section rule gets one `AiService#<group>_guidance` method naming the
  group from its constant and stated once for all sections, never repeated
  into each kind's `.generation_guidance`. The rule is about the concept, not
  about any one kind, so every such group has exactly one of these methods and
  a new group adds another. Don't enumerate the groups here — the constants
  live in `ConceptVocabulary` and each group's guidance method in `AiService`,
  and a count kept in this file has already gone stale once.
- **Provider calls as callables** — a module that orchestrates provider calls
  takes them as a `Provider` struct of callables, with a `providers:` factory
  that returns a fresh one for each thread (`JudgedGeneration::Provider`,
  `ReviewGrading::Provider`, built by `AiService#judged_generation_provider`
  and `#review_grading_provider`). `AiService` keeps the prompts and the calls;
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
  reads them; it keeps only what is about talking to a provider.

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
- No constant *justified* by a vocabulary's size unless it derives from that
  size or a spec asserts the assumption — the same rule as above applied to
  reasoning rather than values. Three separate comments went false as the
  vocabularies grew; each was found by accident. Growing a vocabulary can also
  fail `AiService::MAX_LADDER_GUIDANCE_CHARS`'s spec, which bounds the
  difficulty block's worst case; that failure is a decision to make, not a
  number to raise.
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

- **Rails 8.1.4** + PostgreSQL
- **Solid Queue** — background jobs + recurring hourly cron, gated per user to 8am weekdays for generation and to early afternoon for reminder nudges (no Redis needed)
- **Solid Cable / ActionCable** — mounted but unused; the dashboard learns generation is done by polling `GET /dashboard/status`, since this app's layout never loads Turbo JS
- **Stimulus and importmap** — every page script is a controller under `app/javascript/controllers`, bound with `data-action`; `app/assets/javascripts/code_gym_bootstrap.js` is the one blocking classic script, whose stubs answer for `window.CodeGymRequest` and `window.CodeGymSaveStatus`, record an edit typed before the modules load, and hold a pull-to-refresh reload's content down before the first frame
- **Faraday** — provider API calls (not the official SDKs)
- **Rouge** — server-side syntax highlighting for every code block (`CodeHighlight`)
- **RuboCop and Prettier** — re-indent provider-written exercise code once, at ingest (`CodeFormat`); Prettier runs in Node from `vendor/prettier`
- **web-push** — VAPID-signed daily reminder notifications (`PushDelivery`)
- **BCrypt** — login code digests
- **ActiveRecord Encryption** — encrypts each user's provider API key at rest
- **Railway** — hosting (web + worker services, postgres service)
- **Docker** — Railway builds the image from the `Dockerfile`, as its build logs show, although `railway.toml` still names Nixpacks

## Architecture

```
User logs in (emailed 6-digit code)
  └→ enters their own Anthropic, Gemini or OpenAI API key (stored encrypted per-user;
     the key's prefix determines user.provider)

8am weekdays (Solid Queue cron via config/recurring.yml):
  GenerateDailyExercisesJob
    └→ AiService.for(user) → ClaudeService | GeminiService | OpenaiService
         reads: user.recent_performance (last 10 sessions + ratings + concepts)
         calls: the user's provider with a personalized prompt, in the user's
                chosen language (user.language_for_today)
         saves: DailyExercise { problem_set: jsonb, language } on success, or
         persists last_generation_error(_date) on the user on failure — the
         dashboard learns the outcome by polling GET /dashboard/status and
         reloading (this app loads no Turbo JS, so a live push has
         no subscriber)

User opens dashboard:
  └→ DashboardController#show
       shows today's DailyExercise, or triggers on-demand generation if missing
       (weekdays only; weekends offer a manual "generate anyway" button)
       2-4 sections, sized from recent completion and the competency gate
       unless the user fixed a count in Setup's Daily sections: Code Review and Design Comparison
       are always present; Pattern of the Month, a rotating third
       (Coding Challenge / Architecture Decision / Security Review / Parsons
       Problem), and a rotating fourth (Plan Review / Ambiguity Hunt /
       Pseudocode to Code) compete for the remaining slots, which today's
       count and rotation fill. A two-section Automatic day can gain one
       optional section under the coverage exception

User interacts:
  └→ ResponsesController#create      → auto-saves answers + difficulty rating
       in one debounced fetch (idempotent). Each section's
       difficulty rating renders with that section and gates the Submit
       button — every answered
       section must be rated, and at least one must be answered; a skipped
       section owes no rating. A successful submit chains straight into #review from
       the same click — the dashboard posts the review URL #create hands back —
       which lands back on the submitted-state dashboard either way, with the
       finished review rendered in place when it completed.
  └→ ResponsesController#review      → ResponseReview → AiService#review_sections → ai_review saved,
       then redirects to the dashboard, whose submitted state renders the
       finished review in place — every exit from the action lands there, so
       the page never changes under the user based on how the review went; the
       exits that have a review to show anchor it (`#ai-review`), since the
       day's problems and answers render above it.
       Synchronous; the button disables and relabels while it runs. Fired by a
       successful submit rather than a second click; the button in
       responses/_submission is what remains for a failed or part-finished
       review. A dashboard loaded while the review claim is held shows the
       review as running and polls GET /responses/:id/review_status, then
       reloads once the claim is released or goes stale.
  └→ ResponsesController#email_review→ mails the completed review to the user,
       then returns to the dashboard (where the button lives)
  └→ DailyExercisesController#regenerate → replaces today's set in place (once/day),
       destroying today's response — so it is blocked once that response has been
       reviewed, the same invariant ResponsesController#start_over is blocked on
       (see "One reviewed-response invariant" below)
  └→ HistoryController#index         → every submitted session, newest first,
       paginated 10 per page (pagy, offset) —
       the single destination for viewing any day's problems, answers, and
       review, today's included. There is no per-day review page.
       (concept tags are included in tomorrow's generation prompt)
       No review lands here any more; it is reached by navigation, by a
       post-login bounce back to a /history URL the user had already asked
       for, or by #index's own out-of-range correction. Each entry's
       problems fold by default and the newest entry's review opens, since the
       review is what someone opening the page came for.
  └→ AccountsController#show/destroy  → log out, or permanently delete (anonymize)
       the account in place while preserving all exercise/response/usage history

User browses /learn (independent of the daily flow above):
  └→ LearnController#index            → every concept in the user's vocabularies
       (their language plus the four language-independent buckets), whether or
       not they have ever been assigned one — a library, not a day's plan
  └→ LearnController#show              → one concept's cached reference plus its
       guide, generating either on demand when the row is missing or stale

Every dashboard, /learn and /history load, any day of the week:
  └→ FeaturedConcept.for(user)        → this user's concept for the week, from
       concepts they have met, picked on their first visit of the week and read
       by every visit after — rendered at the top of /learn and as a small
       callout on the dashboard, and marked on every section that carries it
```

## Models

| Model             | Key fields                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| `User`          | email, name, skill_level, focus_areas (jsonb), api_keys (encrypted JSON map of provider to key), provider (the one in use), invite_code_id (nullable fk; the code that admitted the account), trial_started_at / trial_ends_at / trial_consented_at (nullable; a present trial_ends_at is the trial), language, daily_section_count (nullable integer; nil = Automatic), reminder_level (enum: none/ready/ready_and_nudges, default none), anonymized_at (nullable — set on self-service deletion), section_kind_weights (jsonb, default {}), excluded_section_kinds (jsonb, default []), section_kind_levels (jsonb, default {}), locked_section_kinds (jsonb, default []), learning_track (nullable: junior/none; written as "none" by a track choice and read only by `first_run?`, until a cleanup release drops it), level_suggestion_cutoffs (non-null jsonb, default {}), level_suggestions (boolean, default true), level_suggestion_answers (integer, default 0), track_chosen_at (nullable datetime: set when the welcome track choice is recorded; for accounts that predate it, their creation time, so it is a flag, not a clock; null means no decision was recorded, not that the account is undecided) |
| `DailyExercise` | user_id, date, problem_set (jsonb: code_review, design_comparison, pattern, a rotating third key, a rotating fourth key; at most four of them per day), language, generated_at, regenerated_at, dropped_sections (jsonb), plan_notes (jsonb, default {}: what the plan did — `coverage`, `shared_concept`) |
| `DailyResponse` | user_id, daily_exercise_id, answers (jsonb), section_ratings (jsonb, per-section self-rating), ai_review (jsonb), review_provider (which provider wrote the review), concept_tags (jsonb) |
| `ApiUsage`      | user_id, tokens_in, tokens_out, purpose, date, model, cache_read_tokens, cache_write_tokens (the last three null on rows written before they existed) |
| `InviteCode`    | code_digest (SHA-256 of the raw code, unique), label, seats, redeemed_count, expires_at, trial_days, daily_request_cap |
| `PushSubscription` | user_id, endpoint (unique), p256dh_key, auth_key, last_delivered_at — one browser install; transport for the reminder, never intent |
| `FeaturedConcept` | user_id, week_of (the Monday, in the user's zone), bucket, concept — unique on user_id and week_of; one row per week a user had a concept to feature |
| `LevelSuggestionEvent` | user_id, kind, action (applied/dismissed/removed), source (suggestion/setup_edit/skill_level_edit, applied rows only), from_level, to_level, window_size, favourable, too_hard_latest3, newest_result_on |

`ConceptReference` (not listed above — it has no `user_id`; see "The Learn tab"
below) now also carries `guide_plain_language`, `guide_worked_example`,
`guide_pitfalls` (all nullable text). `ConceptReference#guide?` — all three
guide fields present — is the single authority for "does this row carry a
guide". It also
carries `ladder_junior`, `ladder_mid_level`, `ladder_senior`,
`ladder_principal_engineer` (all nullable text), and `ConceptReference#ladder?`
— every ladder field present, one per rung in `KindDifficulty::LEVELS`, derived from the field list the same way `#guide?` is — is the
authority for "does this row carry the difficulty ladder"; `#complete?` is
`guide? && ladder?`. It also carries `lesson` (nullable jsonb): the short
lesson the Learn page shows, in `ConceptLesson`'s shape. `#lesson?` says
whether a row has one and stays out of `#complete?`, so the ladder poll and
`LadderCoverage` never wait on it; `#fully_written?` is `complete? &&
lesson?`, the check `GenerateConceptReferenceJob` skips a row on.

`generation_version` advances on each successful generation write, even when
the provider returns unchanged text or an incomplete ladder. Learn polls that
counter to distinguish a completed rewrite from queued work; `updated_at` and
content equality cannot do that because an unrelated update changes the
timestamp and a valid generation may leave the prose unchanged. Failed calls and skipped
rewrites do not advance it.

`GenerateConceptReferenceJob` uses Solid Queue's per-concept/language
concurrency permit with `on_conflict: :discard`. Users and refresh modes share
the permit because they share the cached reference. Overlapping jobs are
discarded rather than blocked: a blocked job could make another billed call
immediately after an incomplete result. Finishing or failing releases the
permit, so a later explicit retry remains possible. Its expiry derives from
the reference call budget, and the dispatcher recovers expired permits after
an interrupted worker. That lease includes queue time; it does not guarantee
deduplication beyond its expiry. The existing row lock still guards writes
after expiry or for direct `perform_now` calls, which bypass queue controls.

Exercise mix autosaves update the open form without navigating.
`ExerciseMixLadders` supplies the same guidance counts and labels to the initial
Setup render and preference-save responses, including stale-tab corrections.
The client applies the response for its latest edit and keeps guidance
preparation disabled until pending saves finish. Preparing guidance is
optional: difficulty targets already apply without it, and the action writes
concept-specific difficulty descriptions for future generation, not a new set.

## Key Design Decisions

Each entry states what a change must not break. The longer ones point to a
doc under `docs/decisions/`, which holds the full reasoning, measurements and
history; read it before changing that area.

- **Tracks** (`docs/decisions/tracks.md`): A track is `skill_level` itself,
  stored nowhere else. `/welcome` asks once (`User#first_run?`); `PATCH
  /profile` with `choose_track` checks exactly two keys and a
  `LevelSuggestion::LADDER` level under the user-row lock, else 422.
  `TrackChange` is the one rule for which unlocked targets a track change
  clears; suggestions never reach principal engineer. `track_chosen_at` is a
  flag, not a clock.
- **Level suggestions** (`docs/decisions/level-suggestions.md`): One-rung
  level proposals per section kind on the submitted dashboard; nothing moves
  without an explicit Apply. `LevelSuggestion` reads only answered, un-eased,
  `pitched_at`- and `RUBRIC_VERSION`-stamped results, never suggests to or
  from principal engineer, and skips locked kinds. Every rung change records a
  cutoff under the user-row lock, and posted `LevelSuggestionStep`s whose
  `from` differs from the stored rung get a 409.
- **Invite codes and trials** (`docs/decisions/invite-codes-and-trials.md`):
  An invite code starts a trial on a house key. `InviteCode#redeem!` takes a
  seat in one statement, and the seat is taken only when the emailed code is
  entered. `ProviderCredential.for` picks the key, `TrialAllowance.check!`
  runs before every house-key call, and generation, judges and mastery code
  never read trial state (`trial_isolation_spec`); trial branches render only
  for `User#on_trial?`.
- **Per-user API keys** (`docs/decisions/per-user-api-keys.md`): Each user
  keeps one encrypted key per provider in `users.api_keys`; a key's prefix
  picks its provider, and `user.provider` names the one in use, so
  `AiService.for(user)` is the only dispatch. Use `User#store_api_key`,
  `User#api_key` and `User#stored_providers`; no keys stores NULL.
  `ResponseReview` sets `daily_responses.review_provider` on every review.
- **Provider abstraction**: `AiService` is a template-method base class owning prompts, JSON parsing, and usage logging; the concept vocabularies it prompts from live in `ConceptVocabulary`. Subclasses implement `#call` and `#build_connection`, and own which model each purpose routes to (see "Per-purpose model routing" below). Adding a provider means adding a subclass and an `AiProvider.all` entry, not editing the base. The registry follows `ExerciseSection.all`'s explicit class-list pattern, so Zeitwerk loads each class when asked rather than relying on subclasses having already registered themselves. `User` validates against its keys and Setup uses the subclasses' key patterns. `FakeService` has no key pattern and is available only in local environments; a manually stored fake provider is still refused in production.
- **Per-purpose model routing**
  (`docs/decisions/per-purpose-model-routing.md`): Each provider routes a call
  by its `purpose` through its own `MODEL_FOR_PURPOSE`, falling back to
  `DEFAULT_ROUTE`; `model_routing_spec` fails on a key no call site logs. A
  capped call turns thinking off from `ClaudeService::THINKING_OFF` (or
  `OpenaiService::REASONING_OFF`), so a capped purpose cannot route to Opus
  5.5, and an OpenAI model without `none` needs a `reasoning_allowance`.
- **Conversational calls send real turns**
  (`docs/decisions/conversational-calls-send-real-turns.md`): `#duck_response`
  and `#answer_follow_up` pass prior turns as `history:`, with only the new
  turn in `prompt` and stable context in `system`; every other caller omits it
  and must stay byte-identical, which the characterization spec and the
  single-shot group hold. Only the duck passes `cache_system: true`. Gemini
  still flattens history via `#flatten_history`, a known forgery gap.
- **Emailed-code auth**: No passwords and no links. `User#generate_login_code!`
  mints a 6-digit code, stores a BCrypt digest, and returns the raw code for
  the mailer; `User.authenticate_login_code` verifies it against the stored
  BCrypt digest, never against the raw code.
  Codes expire in 15 minutes (`User::LOGIN_CODE_EXPIRY`) and die after five
  wrong guesses (`LOGIN_CODE_MAX_ATTEMPTS`). A code is redeemable **only in
  the browser that requested it** — `SessionsController#verify_code` reads the
  address from `session[:pending_login_email]`, never from a form field, so a
  code cannot be pointed at an account this browser did not ask about. That
  binding is why cross-device login is not possible, which is a deliberate
  cost of having one credential instead of two.
- **Login rate limits** (`docs/decisions/login-rate-limits.md`):
  `SessionsController` bounds guessing of the 6-digit code with per-address
  and per-IP `rate_limit`s on code requests and submissions. The per-IP
  request caps stop account and mail creation by address rotation; the
  per-address submission cap stops rotating IPs. Each limit needs its own
  `name:`, and `LazyCacheStore` resolves `Rails.cache` per call.
- **Per-user request limits** (`docs/decisions/per-user-request-limits.md`):
  Limits guard a trial's house key, so own-key accounts skip them
  (`ApplicationController#own_key?`). Every endpoint billing one provider call
  declares `ProviderCallLimits`, one shared hourly and daily count that runs
  before every other check. `/generate`, Learn prepare actions and the
  per-user generation job permit apply to all accounts. All use
  `LazyCacheStore`.
- **JSONB problem sets**: `problem_set` column stores `{ code_review: {...}, pattern: {...}, challenge: {...} }`. Accessed via convenience methods on `DailyExercise`.
- **Closed concept vocabulary**: each section is tagged with one concept from a fixed per-language list (`ConceptVocabulary::RAILS_CONCEPTS` / `JS_CONCEPTS`), narrowed further at generation time for a schema-review `code_review` day (see below); anything a provider invents is normalized to `"other"` so concept history stays aggregatable.
- **`code_review` content modes**
  (`docs/decisions/code-review-content-modes.md`): `code_review` rolls
  `application_code`, `test_file` or `schema_review`
  (`DailyPlan::CODE_REVIEW_MODE_WEIGHTS`); only `schema_review` narrows to
  `DATA_MODELING_CONCEPTS` via `ConceptVocabulary.selectable_for_section`. A
  Ruby day may be grounded in a `RealSource` excerpt; ingest stamps the
  server's own `scenario`, `source` and `current_schema`, and `RealSource`
  entries are appended, never inserted.
- **Design comparison, the second fixed section**
  (`docs/decisions/design-comparison-the-second-fixed-section.md`): The second
  fixed kind (`ExerciseSection::DesignComparison`): two working pieces that
  differ on one principle; the engineer picks one and names the deciding fact.
  The server rolls A/B order in `.arrange!`, `answer_key` never reaches the
  page, judge or duck before review, and `.reject_unusable!` refuses unusable
  pieces or keys. A day still holds at most `ExerciseSection::MAX_SECTIONS`,
  fixed kinds first.
- **Two-stage generation** (`docs/decisions/two-stage-generation.md`): Weekday
  first generation drafts a set, then `JudgedGeneration` judges each section:
  keep, edit prose (`.prose_fields` only, never code or the planted defect) or
  reject. `JudgeVerdict.parse` is the boundary. A rejection buys
  `.judge_retries` retries with the concept fixed, then a drop recorded in
  `dropped_sections`; a judge failure keeps the draft. The judge never sees
  answer keys or `SERVER_STAMPS`.
- **Scenario flavor** (`docs/decisions/scenario-flavor.md`): Each day's
  scenario setting comes from one prompt line offering a pool from
  `AiService::SCENARIO_POOLS`, rolled once a day by `DailyPlan`
  (`SCENARIO_FLAVOR_WEIGHTS`). Flavor is setting only: concepts come from each
  section's vocabulary, and solving must never need domain or company-internal
  knowledge. `ambiguity_hunt` keeps its own scenario, and a `RealSource`
  `code_review` describes Code Gym.
- **Meta-skill concepts** (`docs/decisions/meta-skill-concepts.md`):
  `ConceptVocabulary::META_SKILL_CONCEPTS` are reasoning skills listed in both
  language vocabularies, hosted only by `code_review` (non-schema modes),
  `pattern` and `challenge`; `parsons_problem` excludes them explicitly.
  `AiService#meta_skill_framing_guidance` requires such a section to still
  hold one findable issue, and `AiService#can_host?` derives hosting from
  `ConceptVocabulary.selectable_for_section`.
- **Alternate framings of a concept reference**
  (`docs/decisions/alternate-framings-of-a-concept-reference.md`): A control
  inside a concept reference asks
  `ConceptReferencesController#explain_differently` for another explanation,
  capped at `MAX_ALTERNATES_PER_CONCEPT`. Nothing is persisted and the shared
  `ConceptReference` row is never written.
  `AiService#explain_concept_differently(user, reference, prior_alternates:)`
  takes no exercise, response or section, since it runs before submission; a
  spec pins that signature.
- **The fourth slot** (`docs/decisions/the-fourth-slot.md`): An optional
  fourth key (`plan_review`, `ambiguity_hunt`, `pseudocode_to_code`) with its
  own language-independent vocabularies and buckets, planned on a separate
  track holding one concept (`FOURTH_SLOT_CAPACITY`). The
  `planted_ambiguities` answer key must never reach the page, a pre-submission
  AI context or logs; strip sites read
  `ExerciseSection.all_answer_key_fields`, and a `reject_unusable!` refusal
  costs only that section.
- **Which sections count** (`docs/decisions/which-sections-count.md`):
  `DailyExercise#active_section_keys` (through
  `ExerciseSection.resolved_keys`) is the single authority for which sections
  a day has; every denominator, the answered count, the submit gate, param
  slices, the duck guard and the review fan-out derive from it. Never count
  `problem_set.keys` or `answers.keys`. `dropped_sections` records why a
  judged day is short.
- **Section kind weight preferences**
  (`docs/decisions/section-kind-weight-preferences.md`): A per-kind multiplier
  (`KindPreferences::MULTIPLIERS`) leans only `SectionRotation#pick_kind`'s
  roll, after the starvation guarantee, and never touches `slot_staleness`.
  Exclusion removes a kind from the pool everywhere, `slot_staleness`
  included; validation refuses one that empties a slot. Storage is sparse, so
  an untouched user stays byte-identical to pre-feature behavior.
- **Difficulty targets and locks**
  (`docs/decisions/difficulty-targets-and-locks.md`): Per-kind level targets
  (`KindDifficulty::LEVELS`) and locks; an unset kind follows `skill_level`
  through `KindDifficulty#rung_for`. A lock suppresses `(reduced)` easing and
  both rating adjustments, first exposure included. Targets and locks change
  prompt text only: `DailyPlan`, `ConceptMastery` and `User#concepts_*` never
  read `KindDifficulty`. `AiService::MAX_LADDER_GUIDANCE_CHARS` bounds the
  ladder block.
- **Drills** (`docs/decisions/drills.md`): A drill (`ConceptDrills`) only
  moves a concept to the front of `User#concepts_needing_reinforcement`; it
  never touches rotation, weights or `KindDifficulty`. It clears on the same
  co-favourable rating that sets mastery to standard.
  `ConceptDrills::MAX_CONCURRENT` caps drills, a group counting as one, with
  `#can_start?`/`#can_start_group?` as the one statement of it. Drills are
  offered only where `DayHosts` says today can tag them.
- **Each section records the rung it was pitched at**
  (`docs/decisions/each-section-records-the-rung-it-was-pitched-at.md`):
  `ProblemSetIngest` strips provider copies, then stamps `pitched_at` (from
  `KindDifficulty#rung_for`) on every returned section, and `eased: true` on
  an unlocked section offered at reduced tier. Both are server-owned. `eased`
  reaches no prompt; `pitched_at` reaches only the review prompt, and the
  judge strips every `ProblemSetIngest::SERVER_STAMPS` field.
- **The Progress page shows the rung each concept is held at**
  (`docs/decisions/the-progress-page-shows-the-rung-each-concept-is-held-at.md`):
  `/progress` shows the rung each concept is held at, grouped as Learn groups
  it. `RungLedger` is the one rule: pure over the responses given, never
  compares to today, uses reviewed un-eased sections and co-favourable
  ratings, and shows `developing_toward` between rungs. The page never shows
  tier, `ConceptMastery`, drills, streak or bucket totals; hosts come from
  `ConceptHosts`.
- **Skill level control** (`docs/decisions/skill-level-control.md`): Skill
  level choices are `KindDifficulty::LEVELS` (`User::SKILL_LEVELS`), edited
  only from Setup's Track select and the welcome page through `PATCH
  /profile`, which 422s anything outside the list. It sets the rung of every
  untargeted kind, never changes automatically, clears targets per
  `TrackChange` under the user-row lock, and bumps
  `section_kind_preferences_version` only when it clears a target.
- **What a usage row records** (`docs/decisions/what-a-usage-row-records.md`):
  Every provider call writes exactly one `ApiUsage` row through
  `AiService#log_usage`, including a call that fails before a reply (zero
  tokens, from `call_and_log`'s rescue). `model` is the routed model;
  `tokens_in` is uncached input, with cache reads and writes in their own
  columns, so each provider subclass subtracts what its API counts inside
  input. `failure` comes from `AiService.failure_code_for`.
- **How a cut-off reply is recognized**
  (`docs/decisions/how-a-cut-off-reply-is-recognized.md`): Providers report
  truncation as data and `AiService#call_and_log` decides it is fatal after
  writing the usage row: Claude `stop_reason == "max_tokens"`, Gemini status
  `incomplete`, OpenAI `incomplete` unless the reason is `content_filter` (a
  refusal). `allow_truncated: true` shows partial prose. Auth errors go
  through `AiService#raise_if_key_rejected` and never log the provider body.
- **What a person is told when a provider fails**
  (`docs/decisions/what-a-person-is-told-when-a-provider-fails.md`): Every
  surface that rescues an `AiService::Error` classifies it with
  `ProviderFailure.classify` and words it through `ProviderFailureText` and
  the `provider_failures` locale table; no error message, provider text,
  status code or key reaches a user. Page scripts show only
  `CodeGymRequest.send`'s `message`, JSON errors go through
  `render_json_error`, and `AiService::BillingError` is never treated as a
  rate limit.
- **What stays out of the logs**: `config/initializers/filter_parameter_logging.rb`
  filters what engineers write (`answers`, `message`, `question`,
  `pseudocode`, `prior_alternates`, the duck's `thread`), the login `code`
  and the push keys from request logs. Entries match as substrings, so `code`
  is anchored (`/\Acode\z/`); a bare `:code` would also hide `pseudocode`
  and every `code_review` key. The same list is Active Record's
  `filter_attributes`, so these columns also read `[FILTERED]` in `inspect`.
  A reply that can quote an engineer's answer (a review grade, a pseudocode
  critique) is parsed with `log_raw: false`, and jobs log `user <id>`, never an
  email.
- **Daily sections setting** (`docs/decisions/daily-sections-setting.md`):
  `User#daily_section_count` is Automatic (nil) or a count in
  `User::DAILY_SECTION_COUNTS`. `DaySize.for` returns a fixed count before
  completion or the gate, and a fixed count never gains a coverage section.
  `ProfileController` accepts only `"automatic"` or a listed count and 422s
  anything else, since Active Record's integer cast would misread it. It is
  not part of the Exercise mix version.
- **What the plan did, on the row**
  (`docs/decisions/what-the-plan-did-on-the-row.md`):
  `daily_exercises.plan_notes` records the planned size and reason on every
  plan, plus coverage and shared concept when they applied
  (`DailyPlan::Result#notes`). It is server-owned, written with the row from
  the plan that produced it and never recomputed while rendering; the size
  excludes any coverage addition, and `RegenerateExerciseJob` rewrites it from
  the new plan.
- **Shared concept on a real struggle**
  (`docs/decisions/shared-concept-on-a-real-struggle.md`):
  `SharedConcept.pick` puts a reduced-tier reinforcement concept that every
  fixed kind can tag (via `DayHosts`) into both fixed sections, only on a host
  nothing else needed (`SharedConcept.placeable?`), so it never evicts a drill
  or reinforcement entry. It is advisory prompt text, never enforced through
  `fixed_concepts:`, and the dashboard line shows only when both delivered
  sections carry it.
- **Waiting retention checks** (`docs/decisions/waiting-retention-checks.md`):
  `DailyPlan` reads due checks for every bucket in the user's slice plus the
  generated language's bucket in one query
  (`User#concepts_due_for_retention_check_in`);
  `ConceptMastery.due_for_retention_check` is the one definition of due. A
  check is selected or reserved only when a section today can tag it
  (`DayHosts`); the rest land on `Result#waiting_checks` as `no_slot` or
  `no_host` and are logged.
- **Coverage exception** (`docs/decisions/coverage-exception.md`):
  `CoverageException` (pure) adds one optional section to a two-section
  Automatic day when the brake is off and no exercise on the previous
  `CAP_WEEKDAYS` weekdays has `plan_notes["coverage"]`, picking a kind for an
  overdue check or one unseen for `GAP_WEEKDAYS`. It respects exclusions,
  reads hosting through `DayHosts`, and gives up the addition when the check
  would not land in it.
- **Competency gate** (`docs/decisions/competency-gate.md`): `CompetencyGate`
  earns an Automatic day's size from rubric-stamped reviews; `DaySize` takes
  the lower of it and completion, and a fixed setting wins outright. The fold
  is pure and runs forward, moves one step a day, resets to two on the brake
  (which empties the growth windows), keeps eased ratings out of growth, and
  reads levels from `pitched_at`. `ReviewedSectionResults` decides which
  sections count.
- **Pausing generation** (`docs/decisions/pausing-generation.md`):
  `User#paused_generation_at` stops only generation the user didn't ask for
  (cron and the dashboard auto-trigger), never submit or review. A held
  unsubmitted set and its draft response move to today
  (`User#carry_held_set_forward!`, `#recover_held_set`) under
  `DailyExercise#with_response_locked`, clearing both regeneration columns; a
  submitted response ends the move, and it is skipped when today already has a
  set.
- **Personalization loop** (`docs/decisions/personalization-loop.md`):
  `User#recent_performance` feeds the last 10 sessions into the generation
  prompt. A skipped section's AI grade is never skill evidence: ratings,
  `ConceptMastery.record_review!` and reinforcement read
  `DailyResponse#answered_concept_tags`. A skipped, due retention check is
  deferred one interval without changing tier, streak or rating, and only for
  a concept answered nowhere on that response.
- **One "answered" authority** (`docs/decisions/one-answered-authority.md`):
  `DailyResponse.answered?` and `#answer_for` delegate to the section kind:
  prose needs more than `ANSWER_MIN_LENGTH` after scaffold labels are removed,
  and Parsons needs a saved complete permutation. The browser holds no copy of
  the rule; it shows the `answered_sections` and `submit_blocker` from each
  reply. History, mastery and generation ask the same authority.
- **Answer scaffolds**: `pattern` and `architecture` ask for multi-part reasoning, so the generator returns an `answer_scaffold` — a short list of labels written for that specific question — inside the section's `problem_set` entry. A fresh textarea starts pre-filled with them; they are plain text in the same plain-string answer, so the user can delete or ignore them. Bounded on ingest (`ExerciseSection::MAX_SCAFFOLD_LABELS` / `MAX_SCAFFOLD_LABEL_LENGTH`) since it is provider output rendered into a form, and absent/unusable values fall back to the kind's `DEFAULT_SCAFFOLD`, so pre-scaffold rows render identically. `ResponsesController` normalizes on write: an answer that is nothing but labels stores as `""`, so reloading offers the scaffold again without storing its labels as the user's work. Other draft text remains intact; grading and read-only displays use `answer_for` as described above.
- **One finish action** (`docs/decisions/one-finish-action.md`): Submit is
  always clickable and the server decides via `DailyResponse#submit_blocker`;
  the browser keeps no copy of the rule. `ResponsesController#create` refuses
  a blocked submit with a 422 and saves nothing, slices ratings to
  `answered_sections` at submission, and a successful submit fires exactly one
  review from the same click. A refused or dropped submission restarts the
  draft autosave.
- **Offline answer saving** (`docs/decisions/offline-answer-saving.md`): The
  dashboard keeps unsent answers in `code_gym/draft_store` and restores them
  only when the stored `DailyResponse#draft_token` matches the rendered one.
  The answers queue retries only saves that got no reply, never a refusal or
  5xx. Confirmed saves, submits, submitted dashboards and every signed-out
  page clear the copy, and submit always stays manual.
- **Folding a section** (`docs/decisions/folding-a-section.md`): Each
  answer-form section is an open native `<details>` the user folds by hand;
  nothing folds automatically except reopening a folded, rated section when
  its answer is edited. The summary holds an `<h2>` (never `role="button"`)
  and the status from `SectionStatusHelper#section_status`. Folding is purely
  visual, nothing inside a section may require visibility, and fold state is
  not persisted.
- **No free-text feedback box**: the answer form once carried an "Anything
  to adjust next time?" field whose text was quoted into the next ten days'
  generation prompts with no instruction about what to do with it. It was
  removed rather than wired up: everything someone would type there has a
  structured home — kind weights and exclusions, difficulty targets and
  locks, drills, the language setting — and scenario taste is what the
  flavor pools vary. A control that quotes text into a prompt and hopes is
  worse than no control. `ResponsesController#create` ignores a
  `feedback_text` param, `recent_performance` carries no feedback, the
  prompt renders none, and the column is gone. The review's
  self-explanation box ("Break this fix into 2-3 steps") went the same way:
  it saved text to a column nothing read, with no grading and no AI call,
  so it was a notebook dressed as a feature. Its endpoint, script, styles
  and column are removed too.
- **Post-hoc difficulty rating**
  (`docs/decisions/post-hoc-difficulty-rating.md`): A reviewed section shows
  how hard the problem was (`DailyResponse::DIFFICULTY_LEVELS`), kept disjoint
  from the grade vocabulary. `AiService#assess_difficulty` takes no response,
  answers, ratings or history, so it can never read out `ConceptMastery` tier.
  Any failure is swallowed so it never costs the review, and the result is
  display-only.
- **Grading rubric** (`docs/decisions/grading-rubric.md`):
  `AiService::RATING_RUBRIC` is the one definition of the four review ratings,
  graded against the section's `pitched_at` rung; per-kind grading notes name
  the main point and never restate the levels. Parsons' rating comes from its
  `fixed_rating` hook. `RubricCheck` only logs agreement and never rewrites a
  rating, and evidence readers that compare ratings to a bar read only
  `RUBRIC_VERSION`-stamped reviews.
- **Review prose judge** (`docs/decisions/review-prose-judge.md`): An optional
  second pass that may reword a graded review's prose fields for plain
  language or length (`AiService#judge_review_prose`); it is never shown the
  answer, problem or grading note. `ReviewProseVerdict.parse` is the boundary,
  any failure returns the grade unchanged, and it runs on Claude only. Turning
  `REVIEW_PROSE_JUDGE` on, or changing its prompt or route, must re-pass the
  doc's activation gate.
- **One reviewed-response invariant**
  (`docs/decisions/one-reviewed-response-invariant.md`): No action destroys a
  reviewed response, since `ConceptMastery.record_review!` has already moved
  mastery off it. `DailyResponse#replace_blocker` states the rule once; start
  over and regenerate refuse on it, and `RegenerateExerciseJob` re-checks it
  under `DailyExercise#with_response_locked`. A review in flight
  (`#reviewing?`) blocks too; a claim past its stale window does not.
- **The Learn tab** (`docs/decisions/the-learn-tab.md`): `/learn` lists every
  concept in the user's slice by `user.language`, never `#language_for_today`,
  and shows explanations before first exposure on this tab only. Guide, ladder
  and `lesson` come from the same `#generate_concept_reference` call, outside
  its required fields; `CONCEPT_REFERENCE_FIELDS` stays unwidened,
  `TRADEOFF_CONCEPTS` is written out, and "seen" reads
  `concept_exposure_count`, never `ConceptMastery`.
- **Recognition guides** (`docs/decisions/recognition-guides.md`): Each named
  `ConceptGroup` or language-independent bucket gets one shared
  `RecognitionGuide` on how to look for that kind of problem. It teaches a
  process and never defines a concept or hints at a defect:
  `#generate_recognition_guide(user, group_key)` is handed no exercise,
  response or history. All three fields are required, rows are never
  rewritten, and nothing else reads a guide.
- **Book citations** (`docs/decisions/book-citations.md`):
  `ConceptBookSources` maps a concept to an array of hand-curated reading
  pointers (title, author, coined term), shown only on `LearnController#show`.
  It must never reach a provider prompt (a spec pins this), and
  `CONCEPT_REFERENCE_FIELDS` and `CONCEPT_GUIDE_FIELDS` stay untouched by it.
  A pointer names a term the book coined, never a chapter or page number.
- **Hand-written lessons** (`docs/decisions/hand-written-lessons.md`):
  `LearnLessons` holds static lessons for Learn-only concepts in no
  vocabulary, rendered at `/learn/lessons/:lesson`; they never reach a
  provider, generation, `ConceptMastery`, retention, drills or Progress. Every
  static reader-facing module is listed in `HandWrittenLearnText::MODULES` and
  answers `.learn_text`, which a spec holds to the plain-language standard's
  checkable rules.
- **What each section kind is**: `SectionKindGuide` holds a hand-written
  summary and a short example for every registered kind, shown in an "About"
  disclosure. Setup's Exercise mix shows one for every kind, always. The
  answer form shows one under a section's summary only until the user has
  answered that kind on a submitted day (`DailyResponse.answered_kinds_for`,
  read from submitted `section_ratings` keys, with no column of its own); the
  submitted dashboard and History never show it. Like `ConceptBookSources` it
  is never sent to a provider, and a spec fails if anything under
  `app/services` or `app/jobs` names it. Each example says what the engineer
  sees and is asked, never an answer, and the ambiguity hunt's names no gap
  and no kind of gap, since the real ones are that section's hidden answer
  key. Its keys must equal `ExerciseSection.keys`, so a new kind fails a spec
  until it has copy.
- **The weekly featured concept**
  (`docs/decisions/the-weekly-featured-concept.md`):
  `FeaturedConcept.for(user)` stores one met concept per user per week
  (`week_of`, the user's Monday), picked by the pure `FeaturedConceptPick`
  from `RungLedger` and exposure, never `ConceptMastery`, drills or pause
  state. `#still_met_by?` re-picks a stale row on read, the insert keeps its
  SAVEPOINT for the unique-index race, it never calls a provider, and
  `#marks?` is the one marking rule.
- **Idempotent saves and frozen evidence**
  (`docs/decisions/idempotent-saves-and-frozen-evidence.md`):
  `ResponsesController#create` reloads every answer save under the response
  row lock; once submitted, answers, section ratings, concept tags and
  submission time are immutable, and a stale autosave gets `submitted: true`
  with nothing changed. A repeated submit returns the existing review URL.
  Each save carries `DailyExercise#draft_scope`, and a mismatched scope gets
  `409 "stale"` and writes nothing.
- **Preview apps** (`docs/decisions/preview-apps.md`):
  `PreviewEnvironment.active?`, read from `PREVIEW_APP`, which only
  `railway.toml`'s `[environments.pr.deploy]` sets, is the single authority
  for PR-app seeding, inline mail and auto-login. `PreviewAutoLogin` registers
  only when active and signs in only an account `PreviewSeed.seeded?`
  recognizes as its own. `PREVIEW_APP` must never be set outside PR
  deployments.
- **Host resolution**: `AppHost.resolve` (`lib/boot/app_host.rb`, deliberately
  outside the autoload path because environment files cannot autoload) reads
  `APP_HOST` and Railway's injected `RAILWAY_PUBLIC_DOMAIN`, tolerating either
  with or without a scheme, and **which one wins depends on the environment**.
  Normally `APP_HOST` does, so production's deliberate custom domain always
  beats an injected value. On a preview app (`PREVIEW_APP` set) the order
  inverts, because a PR environment inherits its base environment's variables
  and therefore arrives carrying production's `APP_HOST` — honoring it there
  would give the preview app `default_url_options` and an ActionCable origin
  check pointed at production's host instead of its own. `AppHost` reads that
  variable directly rather than through `PreviewEnvironment`, which is not
  loadable during `Rails.application.configure`; a spec asserts the two names
  agree.
- **Paginated history**: `/history` renders 10 submitted sessions per page via
  Pagy's offset paginator (`DailyResponse::HISTORY_PAGE_SIZE`). Pagy 43's API
  is a full rewrite — `Pagy::Method`, `pagy(:offset, …)`, and helper methods on
  the pagy object; the `Pagy::Backend`/`pagy_nav` API in most documentation is
  gone. An out-of-range page raises and redirects to the last real page rather
  than rendering the empty state to someone who has sessions. No redirect
  targets a particular entry, so nothing has to work out which page holds one.
- **Code blocks are highlighted on the server**
  (`docs/decisions/code-blocks-are-highlighted-on-the-server.md`): Every code
  block renders through `highlighted_code`, which calls `CodeHighlight.html`,
  the one place code becomes HTML; only Rouge's escaped output is marked safe.
  Output is cached per process in `CodeHighlight::CACHE`, never `Rails.cache`
  or a row. No page loads a browser highlighter, and the `code-lines`
  controller only decides wrapping.
- **Exercise code is re-indented once, at ingest**
  (`docs/decisions/exercise-code-is-re-indented-once-at-ingest.md`):
  `ProblemSetIngest#format_code!` runs each kind's `.code_fields` through
  `CodeFormat.all` once, before the boundary checks, so bounds and every
  reader see the shown layout. Ruby uses whitespace-only RuboCop `Layout` cops
  so a planted defect survives; JavaScript uses Prettier. Unparseable code or
  a formatter that cannot run comes back unchanged, and Parsons blocks are
  never formatted.
- **Parsons input**: drag (SortableJS, CDN) is the primary reorder mechanism;
  up/down arrow buttons are injected by script only if that import fails or
  stalls for 3s. Because dragging is pointer-only, every block is focusable and
  reorderable with Ctrl+↑/↓ (bare ↑/↓ moves focus), with an `aria-live` status
  line announcing each move — that keyboard path, not the arrows, is what keeps
  the section answerable without a mouse.
- **Home-screen app** (`docs/decisions/home-screen-app.md`): Standalone iOS
  launch via `GET /manifest.json` and `apple-mobile-web-app-*` meta tags, a
  phone-width bottom tab bar, and pull-to-refresh. Link icons through
  `PublicFileHelper#versioned_public_path`; keep the maskable mark inside 40%
  of the size from center. Pull-to-refresh reads standalone mode from the
  layout's media query and waits for `CodeGymSaveStatus.pending()` to clear
  before reloading.
- **Display preferences** (`docs/decisions/display-preferences.md`): Theme,
  background pattern, text size, line spacing and reading font, saved through
  `PATCH /profile`. `DisplayPreferences` is the one list of choices, defaults
  first; storage is sparse jsonb and `User` and `ProfileController` refuse
  values outside the lists. Defaults render no `<html>` attribute or extra
  stylesheet; the light palette's media (`#light_palette_media`) drives the
  palette, logo and theme-color together.
- **Push reminders** (`docs/decisions/push-reminders.md`): Optional weekday
  ready and afternoon nudge notifications. Submission alone stops nudges;
  `PushNudgePlan` owns the window and `QUIET_PERIOD`,
  `DailyResponse#submit_blocker` gates the copy, and both are enqueued from
  `GenerateDailyExercisesJob`'s cron branch. `WebPushCredentials` decides
  whether push exists, endpoints stay on `ALLOWED_ENDPOINT_HOSTS`, and
  `Notification.requestPermission()` must be the click handler's first
  synchronous call.

## Railway Deployment

- Project: `zesty-enthusiasm` (ID: `5b53ac62-bdb2-4e8d-a7f2-7a457b06ba4e`)
- Web service: `web-production-246e40.up.railway.app`
- Services: web, worker, postgres
- Web start command: `bundle exec puma -C config/puma.rb` (set in `railway.toml`; don't use `rails server -p $PORT` — Railway start commands run in exec form, so `$PORT` is never shell-expanded, while puma reads `PORT` from ENV)
- Worker start command: `bundle exec rake solid_queue:start` (set in `railway.worker.toml`; the worker service's Settings → Config-as-code file path must point at `/railway.worker.toml`, otherwise it inherits the web config and fails healthchecks)
- Worker pre-deploy: `bundle exec rails db:wait_for_schema` (`SchemaWait`). Railway starts web and worker concurrently and orders neither, so on a PR app — where the database starts empty — a worker that wins the race dies on boot reading `solid_queue_recurring_tasks`. It waits rather than migrating: migrations keep one owner (the web pre-deploy), because `db:migrate` against an empty database performs an *unlocked schema load*, so a second migrator races and the loser dies on a duplicate constraint
- Database pool: `config/database.yml` takes its size from `DatabasePool.size` (`lib/boot/database_pool.rb`), the larger of `RAILS_MAX_THREADS` (default 5) and what one Solid Queue worker process can need while judging: a connection per worker thread in `config/queue.yml`, one more per section for each of those threads' judge fan-out (`DatabasePool::SECTIONS_PER_DAY`, restated because `database.yml` is read before `app/` loads, and held equal to `ExerciseSection::MAX_SECTIONS` by a spec), and two for Solid Queue's polling and heartbeat — 17 today. Nothing needs setting on Railway, and `spec/lib/database_pool_spec.rb` fails if the pool falls below that sum. Connections open only when a thread asks for one, so the web service, which reads the same file, opens none of the extra ceiling unless it uses them. The sizing is so the fan-out never waits for a connection: each judge and retry thread checks one out only to write its `ApiUsage` row, and a pool too small for them would make that write wait out the checkout timeout
- Env vars already set in Railway: `RAILS_ENV`, `RAILS_MASTER_KEY`, all three `ACTIVE_RECORD_ENCRYPTION_*` keys, `DATABASE_URL` (references postgres service)

## What Still Needs Work
1. ~~Email (login code emails won't work yet)~~ — production delivers via Resend's HTTP API (`delivery_method = :resend`; Railway blocks SMTP below Pro). Needs `RESEND_API_KEY`, `MAIL_FROM`, `APP_HOST` on both Railway services: see `docs/deploy/railway-smtp-setup.md`. Sending to teammates requires a verified domain in Resend.
2. ~~`config/environments/production.rb`~~ — done. Resend delivery, `default_url_options`, and `raise_delivery_errors` are wired up from `ENV`.
3. ~~`db:migrate` on Railway~~ — done. `railway.toml` now runs `bundle exec rails db:migrate` via `preDeployCommand` on every deploy, before the new version takes traffic.
4. **Seed a first user**: After deploy, run `rails console` on Railway and create the first user manually, then invite teammates.
5. ~~Remove `/test_login` after buying a domain~~ — done. The route, `SessionsController#test_login`, and `spec/requests/test_login_spec.rb` have been deleted; the `TEST_LOGIN_SECRET` env var can be unset on Railway if still present.

## Local Development

```bash
bundle install
bin/rails db:prepare  # creates the database and loads the schema
bin/dev               # starts the web server only
bin/jobs              # optional: Solid Queue and the recurring schedule
```

Development needs no environment variables. `config/database.yml` points at
a local PostgreSQL through its default socket, Rails generates the
development secret itself, and `config/initializers/active_record_encryption.rb`
derives the encryption keys from that secret. Login code emails open in the
browser through `letter_opener`, so no mail service is needed.

`bin/dev` runs no worker. Development has no `queue_adapter` setting, so jobs
the web process enqueues, such as the dashboard's on-demand generation, run
in that process on Rails' default async adapter. The recurring schedule in
`config/recurring.yml` runs only under `bin/jobs`, every five minutes in
development.

## Tests

RSpec (`spec/` — models, requests, services, jobs, mailers). Run with:

```bash
bundle exec rspec
```

**What to run when.** During a TDD step, run the spec file you are changing.
When a task is done, run the unit suite once
(`bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`). Before opening
a PR, run `spec/system` once. CI runs everything on every PR. A diff that
touches one of the shared authorities named in
`.github/copilot-instructions.md` still runs the full unit suite, not just the
changed file. After a failing run, `bundle exec rspec --only-failures` re-runs
only what failed; RSpec records each example's result in `spec/examples.txt`
(gitignored).

**Parallel runs.** `parallel_tests` splits the suite across processes, each
with its own test database (`code_gym_rails_test`, `code_gym_rails_test2`,
...; see the test section of `config/database.yml`). One-time setup, and again
after a migration:

```bash
RAILS_ENV=test bin/rails "parallel:create[4]" "parallel:prepare[4]"
bundle exec parallel_rspec -n 4 --exclude-pattern "^spec/system/" spec
bundle exec parallel_rspec -n 2 spec/system
```

Two processes for system specs, not four: each starts its own Chromium, and
the fetch-driven specs wait on real timing, so a crowded CPU makes them the
first to flake. Each process keeps its own `spec/examples<N>.txt`, so
`--only-failures` after a parallel run only sees the first process's results;
re-run the failures the summary lists instead. CI runs serially.

`BCrypt::Engine.cost` is set to its minimum for the whole suite
(`spec/support/bcrypt_cost.rb`). At the default cost every `login_as` spent
about half a second hashing, which was most of the suite's runtime.

`spec/system/` holds a small number of real-browser specs (Capybara +
capybara-playwright-driver) covering flows unit/request specs can't fully
verify — rating-gated submit, review loading state — driven exclusively
against a `FakeService` (`provider: "fake"`) test user, never a real API key.
`FakeService` returns every section kind at once rather than the two to four
a real provider is asked for, so system specs can't assert which third
`DailyPlan` chose — cover that in service/job specs instead.
`FakeService` answers the judge's system prompt with a canned `keep` verdict
(plus a matching `better` for a kind the judge solves blind), so the judged
path runs end to end in specs without a rejection unless an example stubs
`judge_section` itself.
A system spec that needs today's set calls `visit_with_todays_set(user)`,
which generates it before the first page load; visiting first would wait out
the dashboard's 3-second "generating" poll. `dashboard_generation_spec.rb` is
the one spec that goes through that poll on purpose.
Running them locally requires a one-time install of the pinned Playwright CLI
and a Chromium build, the same commands CI runs:

```bash
npm --prefix spec/playwright ci
./spec/playwright/node_modules/.bin/playwright-core install --with-deps chromium
```

`npm ci` rather than `npm install`, so setup never rewrites the lockfile. The
CLI version must match what playwright-ruby-client expects, so bump it
together with the gem:

```bash
npm --prefix spec/playwright install --save-exact \
  "playwright-core@$(bundle exec ruby -e 'require "playwright/version"; puts Playwright::COMPATIBLE_PLAYWRIGHT_VERSION')"
```

The npm manifests live in `spec/playwright/`, not the repo
root, so Nixpacks doesn't add a Node phase to the Railway production build.
CI runs system specs in a separate `system_test` job that installs the same
CLI (cached on `spec/playwright/package-lock.json`), while the `test` job runs
everything else via `--exclude-pattern "system/**/*_spec.rb"` — the two halves
run in parallel so unit/request feedback isn't gated behind browser setup.

`spec/support/real_source_default.rb` pins `DailyPlan`'s real-source sub-roll
to `:toy` for every example; a spec that exercises the grounded `code_review`
path opts out with its own `:real` stub. The mode roll is deliberately *not*
pinned this way — it only changes the prompt, so a canned response comes back
through ingest identical either way — but the real-source roll changes what
ingest stamps onto the set, and without the default every example asserting
on a delivered set is nondeterministic at the roll's weight. A spec that needs
a particular mode calls `pin_code_review_mode` (`spec/support/code_review_mode_helpers.rb`),
which stubs only the mode's weights. A `WeightedRoll.pick` stub without
`with(...)` matches every roll, so it replaces the `:toy` pin without failing.

CI runs the suite against postgres 16 on every PR (see `.github/workflows/ci.yml`).

When a scoped run is enough and when it isn't — the shared authorities that
always pull in the full suite — is stated once, in
`.github/copilot-instructions.md` under "Reviewing the pull request itself".

## File Map

One line per file; `docs/file-map.md` has the full descriptions.

- `app/models/track_change.rb` — `TrackChange`: which per-kind targets a track change clears
- `app/services/level_suggestion.rb` — `LevelSuggestion`: pure one-rung level move proposals per kind
- `app/services/level_suggestion/evidence.rb` — reviewed-response history projected into rubric-graded results for suggestions
- `app/services/reviewed_section_results.rb` — `ReviewedSectionResults`: which sections of a reviewed response count as evidence
- `app/services/competency_gate.rb` — `CompetencyGate`: pure fold earning a day's size from reviewed days
- `app/services/day_size.rb` — `DaySize`: the day's planned count and its reason
- `app/services/size_forecast.rb` — `SizeForecast`: whether tomorrow's Automatic set grows or shrinks
- `app/services/competency_gate/evidence.rb` — the gate's query: rubric-stamped reviewed days as `CompetencyGate::Day`
- `app/controllers/welcome_controller.rb` — the first-run track question
- `app/controllers/level_suggestion_dismissals_controller.rb` — records Not now and removed-kind cutoffs with event rows
- `app/models/level_suggestion_step.rb` — `LevelSuggestionStep`: one shown move and its boundary check
- `app/models/level_suggestion_event.rb` — `LevelSuggestionEvent`: one row per answer to a level suggestion
- `app/controllers/level_suggestion_answers_controller.rb` — counts answered proposals
- `app/views/dashboard/_level_suggestion.html.erb` — submitted-day level suggestion card with Apply/Not now
- `app/views/api_keys/_level_suggestions_switch.html.erb` — Setup's "Suggest level changes" switch
- `script/prepare_junior_ladders.rb` (+ `script/junior_ladder_preparation.rb`) — operator ladder coverage report; `--run` queues refreshes
- `spec/requests/existing_account_pages_spec.rb` — exact snapshots of Dashboard, Setup, Account and History pages
- `app/services/ai_service.rb` — `AiService`: provider-agnostic base for prompts, parsing and usage logging
- `app/services/judged_generation.rb` — `JudgedGeneration`: judge, retry and drop sections after the draft
- `app/services/problem_set_ingest.rb` — `ProblemSetIngest`: the generation boundary normalizing provider output
- `app/services/daily_plan.rb` — `DailyPlan`: the day's plan, decided before any provider call
- `app/services/coverage_exception.rb` (+ `coverage_exception/history.rb`) — `CoverageException`: whether a two-section day gains a section
- `app/services/shared_concept.rb` — `SharedConcept`: which reduced-tier concept both fixed sections take
- `app/services/day_hosts.rb` — `DayHosts`: which kinds can tag a concept today
- `app/models/real_source.rb` — `RealSource`: registry of Code Gym's own source excerpts for code review
- `app/models/invite_code.rb` — `InviteCode`: digest, seats, deadline and trial terms of a code
- `app/models/pending_trial.rb` — `PendingTrial`: a trial request held in the session
- `app/controllers/concerns/login_code_requests.rb` — `LoginCodeRequests`: mailing a login code and its limits
- `app/models/provider_credential.rb` — `ProviderCredential.for(user)`: own key, no key, or house key
- `app/models/trial_allowance.rb` — `TrialAllowance.check!`: per-account cap and house-key guard
- `app/models/house_keys.rb` / `trial_mode.rb` — house keys and guards from ENV, and the kill switch
- `app/controllers/trials_controller.rb` — `/trial/start` and `/trial`: code, provider, consent and trial standing
- `app/models/trial_status.rb` — `TrialStatus`: a trial's days left, calls today and end
- `script/mint_invite_code.rb` — mints one invite code and prints it once
- `app/models/provider_failure.rb` — `ProviderFailure`: classifies a rescued provider error
- `app/models/reset_clock.rb` — `ResetClock`: when a failed call's limit lifts
- `app/models/provider_failure_text.rb` — `ProviderFailureText`: one failure as a sentence for a person
- `app/models/concept_reference_failures.rb` — `ConceptReferenceFailures`: per-user cached note of a failed write-up
- `app/controllers/concerns/provider_failure_rendering.rb` — `ProviderFailureRendering`: provider error to sentence or JSON error
- `app/models/judge_verdict.rb` — `JudgeVerdict`: the judge's reply held to its closed vocabulary
- `app/models/concerns/claimable.rb` — `Claimable`: a timestamp column held as a claim on a paid call
- `app/models/concept_vocabulary.rb` — `ConceptVocabulary`: the closed concept lists and what each kind may use
- `app/models/concept_bucket.rb` — `ConceptBucket`: which vocabulary bucket a concept's history records under
- `app/models/kind_preferences.rb` — `KindPreferences`: a user's kind weights and exclusions as plain values
- `app/models/kind_difficulty.rb` — `KindDifficulty`: per-kind difficulty targets and locks; `#rung_for`
- `app/models/concept_hosts.rb` — `ConceptHosts`: which section kinds can host each concept
- `app/models/ladder_coverage.rb` — `LadderCoverage`: which hostable pairs already carry a ladder rung
- `app/models/rung_ledger.rb` — `RungLedger`: the rung a user holds per concept
- `app/controllers/progress_controller.rb` — the `/progress` page
- `app/models/exercise_section.rb` (+ `app/models/exercise_section/`) — `ExerciseSection`: registry of section kinds and their per-kind facets
- `app/models/code_format.rb` (+ `app/models/code_format/`) — `CodeFormat`: re-indents exercise code with RuboCop or Prettier
- `vendor/prettier/` — the Prettier package and `format.mjs`
- `app/models/worked_example.rb` — `WorkedExample.parts`: splits a worked example into code and prose
- `app/models/code_highlight.rb` — `CodeHighlight`: Rouge highlighting, line formatter, lexer map and cache
- `app/helpers/answer_scaffolds_helper.rb` — the textarea scaffold pre-fill value
- `app/models/exercise_section/design_comparison.rb` — the design comparison kind
- `app/views/responses/bodies/_design_comparison.html.erb` / `answers/_design_comparison.html.erb` — design comparison pieces, pick and reason form
- `script/report_answer_positions.rb` (+ `script/answer_position_balance.rb`) — read-only count of better-piece positions
- `script/solve_agreement.rb` — `SolveAgreement`: prints blind-solve agreement for compare_models
- `app/services/claude_service.rb` / `gemini_service.rb` / `openai_service.rb` — per-provider HTTP call, connection and model routing
- `app/models/ai_provider.rb` — `AiProvider`: closed provider registry
- `script/compare_models.rb` (+ `script/model_comparison.rb`) — side-by-side run of stored input through two Claude models
- `script/probe_gemini_capacity.rb` (+ `script/gemini_capacity_probe.rb`) — replays tester-days against Gemini until a limit is hit
- `script/check_gemini_structured_output.rb` (+ `script/gemini_structured_output_check.rb`) — checks Gemini accepts the judge verdict schema
- `app/models/rubric_check.rb` — `RubricCheck`: whether a rating agrees with its listed essential gaps
- `spec/fixtures/review_calibration/` — complete, partial and missed answers for review calibration
- `app/models/review_prose_verdict.rb` — `ReviewProseVerdict`: the prose judge's reply, schema, projection and apply
- `app/services/review_prose_judge.rb` — `ReviewProseJudge.enabled?`: the `REVIEW_PROSE_JUDGE` switch
- `spec/fixtures/review_judge/` — stored reviews for comparing prose judge candidates
- `spec/fixtures/judge/` — stored sections with expected verdicts for comparing judge models
- `app/jobs/generate_daily_exercises_job.rb` — morning batch and on-demand generation
- `app/controllers/responses_controller.rb` — autosave, review and email-review endpoints
- `app/services/review_grading.rb` — `ReviewGrading`: the per-section review fan-out and its rules
- `app/services/caller_zone_thread.rb` — `CallerZoneThread.start`: a thread in the caller's time zone
- `app/services/response_review.rb` — `ResponseReview`: applies a review and returns an `Outcome`
- `app/views/responses/_sections.html.erb` / `_section.html.erb` (+ `bodies/`, `answers/`) — the section loop and shared wrapper
- `app/views/responses/_review_in_progress.html.erb` — running-review line that polls review status
- `app/views/responses/_answered_sections.html.erb` — read-only render of a submitted day
- `app/controllers/daily_exercises_controller.rb` — manual generate and once-daily regenerate
- `app/controllers/history_controller.rb` — paginated list of submitted sessions
- `app/controllers/sessions_controller.rb` — login code request and verification, with rate limits
- `app/controllers/accounts_controller.rb` — Account page: log out and self-service deletion
- `app/models/user.rb` — `User`: auth, `recent_performance`, `language_for_today`, `anonymize!`, encryption
- `app/controllers/concept_references_controller.rb` — a concept explained another way, on demand
- `app/javascript/controllers/concept_alternates_controller.js` — `concept-alternates` controller for a reference's alternate framings
- `app/services/web_push_credentials.rb` — `WebPushCredentials`: the VAPID pair and whether push is configured
- `app/services/push_delivery.rb` — `PushDelivery`: sends one notification, prunes gone endpoints
- `app/models/push_subscription.rb` — `PushSubscription`: one browser install's endpoint
- `app/jobs/send_push_reminder_job.rb` — sends ready and nudge reminders to a user's endpoints
- `app/services/push_nudge_plan.rb` — `PushNudgePlan`: whether an hourly tick nudges
- `app/controllers/push_subscriptions_controller.rb` — enrol and un-enrol push subscriptions
- `app/models/display_preferences.rb` — `DisplayPreferences`: display choices and what the layout renders for them
- `app/assets/stylesheets/display.css` / `display_light.css` — text size, spacing, reading font; the light palette
- `app/views/api_keys/_display_preferences.html.erb` — the Display disclosure on Setup
- `app/views/shared/_pull_to_refresh.html.erb` — installed app's pull-to-refresh indicator and gesture
- `app/javascript/code_gym/request.js` — `CodeGymRequest`: the one way a page script sends a request
- `app/javascript/code_gym/save_status.js` / `app/views/shared/_save_status_banner.html.erb` — `CodeGymSaveStatus`: save banner, save queue and `pending()`
- `app/javascript/code_gym/draft_store.js` — the dashboard's device copy of unsent answers
- `app/controllers/concerns/json_errors.rb` — `render_json_error`: the one JSON error shape
- `app/views/shared/_push_script.html.erb` — mounts the `push-launch` re-subscribe controller
- `app/views/accounts/_push_reminders.html.erb` — the Account page reminder toggle
- `app/views/pwa/service-worker.js.erb` — service worker that shows the notification
- `app/services/schema_wait.rb` — `SchemaWait`: worker pre-deploy wait for the schema
- `app/services/preview_environment.rb` — `PreviewEnvironment`: whether this is a Railway PR deployment
- `app/services/preview_seed.rb` — `PreviewSeed`: demo content for PR apps
- `app/services/preview_mail.rb` — `PreviewMail`: inline mail delivery in preview apps
- `app/controllers/concerns/preview_auto_login.rb` — `PreviewAutoLogin`: preview-only auto-login callback
- `lib/boot/database_pool.rb` — `DatabasePool.size`: the database pool size
- `lib/boot/app_host.rb` — `AppHost.resolve`: the app's host from ENV
- `app/services/fake_service.rb` — `FakeService`: deterministic zero-cost provider for tests
- `app/controllers/learn_controller.rb` — the `/learn` library, concept pages and generation triggers
- `app/controllers/concerns/learn_scope.rb` — `LearnScope`: the user's vocabulary slice and URL checks
- `app/models/concept_drills.rb` — `ConceptDrills`: starts and stops drills, owns the cap
- `app/controllers/concept_drills_controller.rb` — drill endpoints under `/learn`
- `app/views/shared/_featured_concept.html.erb` — the weekly featured concept callout
- `app/models/featured_concept.rb` — `FeaturedConcept.for(user)`: this week's stored pick
- `app/services/featured_concept_pick.rb` — `FeaturedConceptPick`: pure rule choosing among met concepts
- `app/helpers/featured_concept_helper.rb` — featured concept per request, section marking and tagline rule
- `app/views/responses/_featured_marker.html.erb` — marker on a section carrying this week's concept
- `app/models/concept_book_sources.rb` — `ConceptBookSources`: hand-curated book pointers per concept
- `app/models/concept_lesson.rb` — `ConceptLesson`: short-lesson sections, limits and boundary check
- `app/models/learn_lessons.rb` — `LearnLessons`: hand-written Learn-only lessons
- `app/models/section_kind_guide.rb` — `SectionKindGuide`: each kind's hand-written summary and example
- `app/models/hand_written_learn_text.rb` — `HandWrittenLearnText::MODULES`: static reader-facing text modules
- `app/models/recognition_guide.rb` — `RecognitionGuide`: cached "how to look for these" per group
- `app/jobs/generate_recognition_guide_job.rb` — writes one missing recognition guide
- `app/models/concept_group.rb` — `ConceptGroup`: a concept's display group on the Learn index
- `spec/system/learn_filter_spec.rb` — Learn filter matches the label shown on screen
- `config/initializers/content_security_policy.rb` — the content security policy
- `spec/conventions/app_views_spec.rb` — fails on inline scripts, `on*` handlers or `javascript:` URLs
- `spec/conventions/app_source_spec.rb` — fails on stray `Thread.new` and `send(:...)` in `app/`
- `spec/system/` — real-browser specs against the fake provider
- `config/recurring.yml` — Solid Queue cron schedule
- `railway.toml` — Railway build and deploy config
