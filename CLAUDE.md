# Code Gym Rails — Project Context for Claude Code

## What This Is

A team Rails app for daily personalized coding exercises. Each engineer logs in (emailed 6-digit code, no passwords), adds their own AI provider API key (Anthropic, Gemini or OpenAI), and gets an AI-generated problem set each morning tailored to their performance history. They answer sections and rate difficulty before submitting. Submission requests an inline AI review; the submitted work and review feed into the next day's problem generation.

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
  parsing, and usage logging; subclasses implement `#call` and
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
  many sections a day has, `ConceptBucket` for which vocabulary a concept
  records under. Derive from the authority; never recount.
- **One prompt line per vocabulary group** — a concept group that needs a
  cross-section rule gets one `AiService#<group>_guidance` method naming the
  group from its constant and stated once for all sections, never repeated
  into each kind's `.generation_guidance`. The rule is about the concept, not
  about any one kind, so every such group has exactly one of these methods and
  a new group adds another. Don't enumerate the groups here — the constants
  and their guidance methods sit next to each other in `AiService`, and a
  count kept in this file has already gone stale once.

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
- **Faraday** — provider API calls (not the official SDKs)
- **web-push** — VAPID-signed daily reminder notifications (`PushDelivery`)
- **BCrypt** — login code digests
- **ActiveRecord Encryption** — encrypts each user's provider API key at rest
- **Railway** — hosting (web + worker services, postgres service)
- **Nixpacks** — auto-detected build from `railway.toml`

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
         reloading (this app loads no Turbo/Stimulus JS, so a live push has
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
  └→ ResponsesController#review      → AiService#review_response → ai_review saved,
       then redirects to the dashboard, whose submitted state renders the
       finished review in place — every exit from the action lands there, so
       the page never changes under the user based on how the review went; the
       exits that have a review to show anchor it (`#ai-review`), since the
       day's problems and answers render above it.
       Synchronous; the button disables and relabels while it runs. Fired by a
       successful submit rather than a second click; the button in
       responses/_submission is what remains for a failed or part-finished
       review.
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

Every page load, any day of the week:
  └→ ConceptReference.featured        → the day's one globally-featured concept,
       picked on the first visit that asks and read by every visit after —
       rendered at the top of /learn and as a small callout on the dashboard
```

## Models

| Model             | Key fields                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| `User`          | email, name, skill_level, focus_areas (jsonb), api_key (encrypted), provider, language, daily_section_count (nullable integer; nil = Automatic), reminder_level (enum: none/ready/ready_and_nudges, default none), anonymized_at (nullable — set on self-service deletion), section_kind_weights (jsonb, default {}), excluded_section_kinds (jsonb, default []), section_kind_levels (jsonb, default {}), locked_section_kinds (jsonb, default []), learning_track (nullable: junior/none; nil = no decision), track_evidence_cutoffs (non-null jsonb, default {}) |
| `DailyExercise` | user_id, date, problem_set (jsonb: code_review, design_comparison, pattern, a rotating third key, a rotating fourth key; at most four of them per day), language, generated_at, regenerated_at, dropped_sections (jsonb), plan_notes (jsonb, default {}: what the plan did — `coverage`, `shared_concept`) |
| `DailyResponse` | user_id, daily_exercise_id, answers (jsonb), section_ratings (jsonb, per-section self-rating), ai_review (jsonb), concept_tags (jsonb) |
| `ApiUsage`      | user_id, tokens_in, tokens_out, purpose, date, model, cache_read_tokens, cache_write_tokens (the last three null on rows written before they existed) |
| `PushSubscription` | user_id, endpoint (unique), p256dh_key, auth_key, last_delivered_at — one browser install; transport for the reminder, never intent |

`ConceptReference` (not listed above — it has no `user_id`; see "The Learn tab"
below) now also carries `guide_plain_language`, `guide_worked_example`,
`guide_pitfalls` (all nullable text) and `featured_on` (nullable date, uniquely
indexed). `ConceptReference#guide?` — all three guide fields present — is the
single authority for "does this row carry a guide"; `featured_on` is the day
the row was the featured concept, and nil means it never has been. It also
carries `ladder_junior`, `ladder_senior`, `ladder_principal_engineer` (all
nullable text), and `ConceptReference#ladder?` — all three ladder fields
present, derived from the field list the same way `#guide?` is — is the
authority for "does this row carry the difficulty ladder"; `#complete?` is
`guide? && ladder?`.

`generation_version` advances on each successful generation write, even when
the provider returns unchanged text or an incomplete ladder. Learn polls that
counter to distinguish a completed rewrite from queued work; `updated_at` and
content equality cannot do that because featuring changes the timestamp and
a valid generation may leave the prose unchanged. Failed calls and skipped
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

- **Junior learning track**: an optional first-run preset and suggestions to
  change existing difficulty targets, with no separate generation policy.
  `User#first_run?` requires a saved, undecided account (`learning_track:
  nil`) with no exercise ever created. Dashboard and Setup send that account
  to `/welcome`. Junior sets every
  registered kind to `junior` through `PATCH /profile` with the existing
  preference version. Under the user-row lock, the endpoint requires both
  that version and the exact registry-derived preset; an incomplete or
  mismatched choice saves nothing. The new-account targets are unlocked so
  ordinary easing still applies. Junior also sets `skill_level` to
  `LearningTrack::START_SKILL_LEVEL` (`beginner`), and the endpoint refuses a
  junior choice without it, like any other mismatch with the preset. Targets
  already decide every kind's rung, so the skill level changes the generation
  prompt's profile line and which scenario pools the day rolls from (see
  "Scenario flavor" below), never a rung. Nothing resets it: after a kind steps up to
  senior, or after leaving the track, the profile still says beginner until
  the user changes it on Setup. Experienced records
  `"none"` without changing targets. Existing accounts are not enrolled or
  prompted, and joining after the first-run choice is refused.

  **Existing accounts are told apart by a backfill, not a date.**
  `AddLearningTrackToUsers` adds the nullable string with no default and the
  jsonb map; `BackfillLearningTrackForExistingUsers` then sets every row it
  finds to `"none"`, so an account that predates the track is never asked. A
  `"none"` posted by an account already at `"none"` is accepted and changes
  nothing, so a repeat Leave does not error; joining stays refused. The backfill
  cannot be undone, since its rows look like any other `"none"`. The exercise
  check in `first_run?` is what keeps the preview app's seeded account, created
  after migrations run, from being asked. One gap is accepted: an account
  created while the migration has run but the old code still serves arrives
  as `nil` with no exercises and is asked once the new code is live, which is
  right for an account that new. In specs, `create_user_with_key` and
  `create_fake_provider_user` default to `"none"`, standing for backfilled
  accounts; a first-run spec passes `learning_track: nil`.

  **Suggestions use reviewed work, not mastery tiers.** `TrackGraduation`
  checks unlocked kinds in registry order: first a step back from senior when
  at least two of the latest three senior results are `too_hard` (two of two
  qualifies), then a step forward after three consecutive favourable junior results.
  Favourable means both the existing AI and self-rating rules agree. Otherwise,
  a lead already targeted above junior can propose the remaining junior kinds
  as one removable bundle. `ExerciseSection.leads_learning_track?` owns which
  kind leads (currently code review); any unfavourable result in a member's
  latest three junior results vetoes that member. No own results is allowed.
  Locked kinds are omitted; exclusions remain a scheduling preference.

  `TrackGraduation::Evidence` preloads exercises for the latest 60 submitted
  responses with stored review data. Only reviewed responses and answered,
  un-eased sections with a `pitched_at` stamp and an AI rating contribute.
  Historical unstamped work contributes nothing. The read cap bounds queries;
  rare kinds may need the lead-based suggestion. The AI rating's calibration
  for these moves is unverified, and a higher lead target is not proof of
  ability in another kind. Suggestions require an explicit Apply.

  **A cutoff prevents the same work immediately proposing another move.**
  Not now records each kind's current level and the newest reviewed response
  date, falling back to the user's today. Moving between junior and senior in
  either direction records the destination level and today's date in the
  user's zone. Evidence through that date is ignored at that level; a
  lead-based proposal after a cutoff also needs three fresh favourable lead
  results. The profile join check and versioned level changes run under the
  user-row lock; dismissal merges into the reloaded map under that same lock
  and keeps a later valid cutoff at the current level. Its earlier evidence
  read cannot undo a newer dismissal or level-change cutoff. A different-level
  or malformed entry is replaced; `TrackGraduation.cutoff_date` is the shared
  reader for dismissal and proposal filtering.

  **Setup and dashboard saves settle in place.** Apply changes only listed
  bundle members through the existing versioned profile endpoint, then
  dismisses removed members separately. That second request is tracked as
  pending, but the two writes are not atomic: its failure leaves the applied
  levels saved and the shared save error visible. Not now dismisses the whole
  original bundle. A stale Apply (409) reloads only after pending saves clear;
  a save still pending after ten seconds cancels the reload. Leaving on Setup
  preserves targets, locks, exclusions and pending Exercise mix edits.
  No junior targets remaining automatically records `"none"`; the track
  does not keep proposing steps back after completion or leaving.

  Generation, review, both judges and `ConceptMastery` never read track state;
  `spec/services/learning_track_isolation_spec.rb` pins that separation and
  byte-identical generation/judge calls for equal difficulty settings.
  The key guide appears only for a track account with no exercises. Its
  copy remains scrollable: in Chromium at 390×844, the guide is about 893px
  tall at default text, 1,321px at 125%, and 1,681px at 140%, measured in an
  older headless Chromium once the OpenAI section was added (the same build
  measured the guide without it at 711, 1,069 and 1,340). Even at default
  size it extends below the initial viewport; enlarged text needs vertical
  scrolling. There is no unconditional one-screen promise or hidden content.

  **Operator preparation rewrites shared wording.** Run
  `bin/rails runner script/prepare_junior_ladders.rb <operator_user_id>` first
  for per-kind coverage and deduplicated gaps across both languages.
  It writes nothing. Adding `--run` queues missing ladders through
  `GenerateConceptReferenceJob` with `refresh: true`, billed to that active
  operator's own key. A refresh rewrites the whole shared reference and guide,
  including rows that already have a guide, for every user. Production coverage,
  billed cost and completion remain unmeasured until this runs there.
- **Per-user API keys**: Each user provides their own Anthropic, Gemini or OpenAI key. Zero shared cost. The key's prefix (`sk-ant-`, `AIza`/`AQ.`, or `sk-proj-`/`sk-svcacct-`/legacy `sk-`) selects `user.provider`; the OpenAI pattern requires alphanumerics straight after a bare `sk-`, so it can never claim an Anthropic key whatever order the patterns are tried in. `AiService.for(user)` dispatches to the right subclass. Stored encrypted with `encrypts :api_key` (ActiveRecord Encryption) in the `users.api_key` column. The `ACTIVE_RECORD_ENCRYPTION_*` env vars are wired in via `config/initializers/active_record_encryption.rb` (Rails does not read them from ENV on its own); development derives throwaway keys from `secret_key_base` automatically.
- **Provider abstraction**: `AiService` is a template-method base class owning prompts, concept vocabularies, JSON parsing, and usage logging. Subclasses implement `#call` and `#build_connection`, and own which model each purpose routes to (see "Per-purpose model routing" below). Adding a provider means adding a subclass and an `AiProvider.all` entry, not editing the base. The registry follows `ExerciseSection.all`'s explicit class-list pattern, so Zeitwerk loads each class when asked rather than relying on subclasses having already registered themselves. `User` validates against its keys and Setup uses the subclasses' key patterns. `FakeService` has no key pattern and is available only in local environments; a manually stored fake provider is still refused in production.
- **Per-purpose model routing**: each provider picks its model from its own
  `MODEL_FOR_PURPOSE`, keyed by the same `purpose` string `ApiUsage` records,
  and falls back to its `DEFAULT_ROUTE` for any purpose not listed. The tables
  are per provider because the providers share no model names and turn thinking down
  differently (`effort` on Claude, `thinking_level` on Gemini,
  `reasoning.effort` on OpenAI). OpenAI routes generation and its retry to
  `gpt-6.1-sol` at `high` effort and everything else to `gpt-6-sol` at an
  explicit `medium`; none of those routes has been compared against another
  model. A capped OpenAI call sends effort `none` from
  `OpenaiService::REASONING_OFF`, its counterpart to `THINKING_OFF`. GPT-6.1
  Sol and GPT-6 Astra have no `none`, so like Opus 5.5 neither can take a
  capped purpose, which is why only uncapped generation goes to 6.1 Sol. `call_and_log`
  hands `purpose:` to `#call` for this. Because an unlisted purpose falls back
  silently, `spec/services/model_routing_spec.rb` fails on a key that no call
  site logs, so a typo cannot quietly route nothing.

  `generate_exercise` goes to `claude-opus-5-5` at `medium`
  effort, not `low`, because nothing measures whether `low` holds quality.
  Opus 5.5 replaced Opus 5 on this route because it costs less ($4/$20 per
  million tokens against $5/$25) on the same tokenizer and context; `medium`
  is also its default effort, stated explicitly so a change to that default
  cannot move this route silently. Thinking cannot be turned off on Opus 5.5,
  which this route never asked for anyway: `#call` sends no `thinking` field
  unless a caller passes `max_tokens`, and generation does not. Generation
  keeps thinking on and the 16,000-token `MAX_TOKENS`, and Opus 5.5 shares
  Sonnet 5's tokenizer, so that cap covers the same output. What changes is latency, which
  matters less than it would on a request: every generation runs in a job
  under the 300-second `GENERATION_READ_TIMEOUT`, so a slower model makes a
  user who opened an empty dashboard wait longer but does not fail sooner.
  `retry_section` is billed separately, but it uses the same route on each
  provider, because it is a narrower generation call rather than a different
  kind of work.

  The default route is `claude-sonnet-5-5` at an explicit `effort: "high"`,
  5.5's own default, stated so a change to it cannot move every default-route
  purpose silently. Sonnet 5.5 costs the same as Sonnet 5 and shares its
  tokenizer, but its effort levels are recalibrated, so every uncapped
  default-route purpose changed cost and latency by an unmeasured amount when
  it moved.

  `judge_section` goes to `claude-sonnet-5-5` at `effort: "high"`, named explicitly even though it
  is the default route, so usage rows and the comparison tooling agree on what
  ran. Sonnet first because the judge has to read code carefully and answer in
  a closed vocabulary, which is where a smaller model's false rejections would
  show. Haiku 4.5 is the comparison candidate at half the price;
  `script/compare_models.rb judge` runs one stored day's draft through both,
  and `judge_fixtures` runs both over the fixture set with its expected
  verdicts. The route stays on Sonnet until those are read, and moving it is
  editing one entry.

  Review stays on `claude-sonnet-5-5` pending a comparison with `claude-opus-5-5`,
  and `duck_thread` and `pseudocode_translate` pending one with
  `claude-haiku-4-5`. `script/compare_models.rb` runs a stored day through both
  models of a pair and prints the results with tokens and time for a person to
  judge. Two constraints apply before routing any of them, both noted beside
  the table. `#call` turns thinking off whenever a caller passes `max_tokens`,
  using the routed model's entry in `ClaudeService::THINKING_OFF` (`between_tools`
  on Sonnet 5.5, `disabled` on Haiku 4.5). Opus 5.5 has no thinking-off setting
  and no entry, so a capped purpose cannot move to Opus: the call raises before sending. And Haiku 4.5 caches only a
  prompt of 4,096 tokens or more, above the duck's system prompt, so moving
  `duck_thread` there ends the caching bet described below.
- **Conversational calls send real turns**: `AiService#duck_response` and
  `#answer_follow_up` pass prior turns as `history:` — an ordered
  `{ role:, content: }` array — while `prompt` carries only the new user turn,
  and the section/review context that is stable across a thread lives in
  `system`. `ClaudeService` renders `history` as a Messages API `messages`
  array; `GeminiService` folds it back into `input` via
  `AiService#flatten_history`, because the Interactions API has no equivalent
  shape (its stateless multi-turn form is a `Step[]` whose model steps must be
  replayed exactly as received, and only assistant *text* is stored here). The
  keyword is the third instance of the additive-kwarg pattern after
  `cache_system:` and `max_tokens:`: every other caller omits it and is
  byte-identical. Two specs hold that jointly, because neither can alone —
  `spec/services/provider_request_characterization_spec.rb` pins that an empty
  history serializes to the same body as before at the `#call` boundary, and
  `ai_service_spec`'s "single-shot purposes" group drives the other public
  entry points and asserts the history each one reaches `#call` with is empty.
  **`duck_response` passes `cache_system: true`; the other conversational
  caller does not.** Counted with `count_tokens` against `claude-sonnet-5` (5.5 shares its tokenizer)
  rather than estimated from characters, the merged duck prompt runs 993-1,182
  tokens across the stored `code_review` exercises — median 1,059 — and 1,364
  for the largest excerpt `RealSource` can actually produce. That last figure
  predates the current-schema block a grounded migration day now adds, so
  those prompts run larger, which only strengthens the case for caching.
  Against Sonnet 5.5's 512-token minimum every one of those prompts caches,
  the shortest sections included.

  **It is a bet, not a free win, and this is the shape of it.** A thread is
  multi-turn by design but nothing forces a second turn, and the first turn of
  every thread pays the write. Writing the prefix costs 1.25x and reading it
  0.1x, against 1x per uncached turn, so a thread that stops after one turn
  costs 25% more than it would have, a two-turn thread saves 32.5%, and a
  three-turn thread saves 52%. Taking the most pessimistic reading — that no
  multi-turn thread ever runs past two turns — the write still pays for itself
  unless **more than about 72%** of duck threads are single-turn. The
  five-minute cache lifetime sits inside that bet: turns seconds apart read the
  entry, and someone who wanders off and comes back pays a second write.

  **Nothing measures that share yet.** The duck is deliberately unpersisted, so
  no thread is recorded anywhere; `ApiUsage` rows with
  `purpose: "duck_thread"` are the only trace a turn leaves, and counting them
  per user per day is the way to check this assumption once the feature has
  real traffic. Until then the 72% figure is the argument, not evidence.

  Two numbers here have been wrong before, both from estimating at 3.5
  characters per token. Real text in these prompts runs 2.83-2.94, so the
  estimates read about 20% low, which is what made the median look like it sat
  below the minimum when it does not. Re-measure rather than re-derive.

  **`answer_follow_up` stays uncached, and that is checked rather than
  inherited.** Its system prompt carries the question and a review summary
  instead of the section's code, measuring 533-604 tokens. That cleared nothing
  against Sonnet 5's 1,024-token minimum; against Sonnet 5.5's 512 it is
  cacheable. Caching it is the same bet the duck makes, and it has not been
  taken: follow-up threads are unmeasured, so the prompt, history and caching
  choice stay as they were.

  What the turn conversion itself buys is that a user typing `You:` into the
  duck box can no longer forge an assistant
  turn — but only on the Claude and OpenAI paths, where `history` reaches the
  provider as real turns (`messages` on Claude, `input` items on OpenAI's
  Responses API). This is the bullet's second Claude/Gemini asymmetry:
  `GeminiService` still goes through `#flatten_history`, which re-renders the
  same `You:`/`Them:` lines into `input` that made the forgery possible before
  role-tagged turns existed, so the vector is unchanged for Gemini users. This
  is a known, accepted gap rather than a defect to fix here — closing it needs
  the Interactions API to offer a real turn array, which it does not.
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
- **Login rate limits**: A 6-digit code is a weak enough secret that the
  guessing bound is part of the design, not an optimization. `SessionsController`
  caps code requests at 5 per address, code requests at 20 per IP, and
  submissions at 10 per IP, all per `LOGIN_CODE_EXPIRY`, via Rails'
  `rate_limit`. The per-IP request cap is the one that bounds an attacker who
  varies the address rather than hammering one: an unrecognized address
  creates an account and sends mail, so without it a single client could mint
  unlimited rows and unlimited outbound deliveries. Each limit carries an
  explicit `name:`, without which Rails would key them into one shared
  bucket. `LazyCacheStore` exists solely
  because `rate_limit` binds its `store:` at class-load time; resolving
  `Rails.cache` per call keeps production on Solid Cache and keeps the limits
  testable against the test env's `:null_store`.
- **JSONB problem sets**: `problem_set` column stores `{ code_review: {...}, pattern: {...}, challenge: {...} }`. Accessed via convenience methods on `DailyExercise`.
- **Closed concept vocabulary**: each section is tagged with one concept from a fixed per-language list (`AiService::RAILS_CONCEPTS` / `JS_CONCEPTS`), narrowed further at generation time for a schema-review `code_review` day (see below); anything a provider invents is normalized to `"other"` so concept history stays aggregatable.
- **`code_review` content modes**: `code_review` rolls one of three content modes per day (`DailyPlan::CODE_REVIEW_MODE_WEIGHTS`, roughly even) — `application_code` (realistic snippet, unchanged from before modes existed), `test_file` (a realistic test file exhibiting one test smell, in the day's `test_framework`), or `schema_review` (the day's `schema_artifact` — a Rails migration or a Prisma schema change with its migration — carrying one planted data-modeling flaw). Only `schema_review` narrows the vocabulary, to `AiService::DATA_MODELING_CONCEPTS` (`ProblemSetIngest.code_review_vocabulary`); the other two modes get the full list minus those concepts, unchanged from before modes existed. `pattern` and the rotating third deliberately keep the full vocabulary regardless of the day's `code_review` mode, so a due data-modeling retention check has somewhere to land on a non-schema-review day that includes either of them — a short day may include neither, and `DailyPlan` only offers a check a chosen kind can host. Because that lets a data-modeling concept surface where no schema artifact is shown, `AiService#data_modeling_idiom_guidance` adds one prompt line — stated once for all sections, named from the constant — telling the model to express such a concept in the host section's own idiom (a `pattern` question about `wrong_cardinality` asks how the relationship should be modeled, not for a migration to review). Advisory prompt text, no new machinery; `[retention]` logs are the check on whether it lands.

  **Two of the three modes can be grounded in Code Gym's own source.** On a
  `ruby_rails` day whose mode is `application_code` or `schema_review`, a
  second roll (`RealSource::WEIGHTS`, 35% real) may hand the model a real
  excerpt from this codebase instead of asking for a toy scenario — one
  planted flaw, in a modified copy of a method or in a new migration modelled
  on a real one, through the same ingest and grading as any other
  `code_review`. `test_file` is untouched by construction: it has no pool.
  `RealSource` (`app/models/real_source.rb`) is the curated registry, in
  `ExerciseSection`'s shape — closed lists, one class per kind of excerpt
  (`Method`, scoped by name and sliced with Prism; `Migration`, the whole
  file), nothing eligible unless added there. It exists for exercise
  *quality*, not safety: nothing in this source is a per-instance secret, and
  `ai_service.rb` is in the pool. `DailyPlan` decides the excerpt
  (`Result#code_review_source`); `AiService` reads its text at prompt time;
  `ProblemSetIngest` stamps the server's own `scenario` — which names the
  file and says the copy is altered, so the exercise cannot read as a bug
  report against deployed code — and a `source` id into the section. That id
  is the only persisted trace (`code_review_mode` itself never is), and
  `RealSource.last_seen_for` reads it back so `.pick` can prefer what this
  user has not seen, in the same never-seen-first, list-order-ties shape
  `SectionRotation` uses. Gated to `RealSource::LANGUAGE` because this
  codebase is Ruby; a `javascript` day stays toy. A migration is reference
  material, never mutated in place — a one-line `add_column` has no room for
  a flaw — so the model writes a next migration for the same table. A
  migration file never states everything its table has (`t.references` adds
  an index it never names, and later migrations can change the table), and
  the grader never sees the original, so
  `RealSource::Migration#current_schema` also slices each table the migration
  touches out of `db/schema.rb`, found and sliced with Prism the way a
  `Method` is, and the instruction asks for a snippet that applies cleanly to
  it: no column the table already has, and no index whose default name
  already exists. A modified copy of the original is not offered, because the
  current table beside it would show the fix. `ProblemSetIngest` stamps that
  definition into the section as `current_schema`, server-owned like
  `scenario`, and deletes one a provider returns on any other day or in any
  other section. The page shows it collapsed under the snippet, and the
  grader, the duck and the difficulty assessment all read it. That gives the
  model what it needs to avoid a column or index the table already has; it
  does not enforce it, and nothing checks the output. A stale entry, including a
  migration whose table has left the schema, is skipped with a warning rather
  than failing generation; a spec holds every entry resolvable and inside
  `MIN_LINES..MAX_LINES`. Design:
  `docs/superpowers/specs/2026-09-11-real-source-code-review-design.md`.

  **Self-reference here is deliberate, and the pool leans into it.** Code Gym
  is a working learning app, so its own pause-and-resume, spaced-repetition,
  mastery-cooldown, adaptive-sizing and reminder methods are the one place an
  education-domain exercise can be grounded without a fictional scenario the
  engineer would first have to learn — their lived context in this app
  supplies that fluency. Teaching new concepts from a personal-interest domain
  was tried and rejected for exactly the missing-prerequisite problem (see
  "Scenario flavor" below); grounding in real source is the education-domain
  answer to it. There is no rule against Code Gym framing to relax: the
  registry's own safeguards — curated list, one planted flaw in a modified
  copy of a method or a new migration modelled on a real one, a scenario that
  says so — are the whole guardrail. Entries are appended, never inserted,
  because list order is the never-seen drain order, and a method at exactly
  `MAX_LINES` is left out since the next edit would evict it.
- **Design comparison, the second fixed section**: every day holds
  `code_review` and `design_comparison` (`ExerciseSection::DesignComparison`,
  `fixed? true`), each in a slot of its own ahead of pattern, third and
  fourth. A day still holds at most `ExerciseSection::MAX_SECTIONS` (4), so
  a day of N sections has N − 2 optional slots, which pattern, the thirds
  and the fourths compete for on staleness. With five slots, a payload with
  a shape in every slot would resolve to five sections: `ProblemSetIngest`
  drops the slots the plan left empty whenever a payload would resolve past
  the maximum, and `ExerciseSection.resolved_keys` caps a stored row at
  `MAX_SECTIONS`, fixed kinds first, so a requested section is never the one
  cut. Below the maximum an unrequested extra is still kept and warned about.

  **The task.** Two working pieces of code that meet the same stated
  behavior, retries and failures included, and differ on one design
  principle, the tagged concept. The engineer picks the piece the stated
  system should use and says which stated fact decides it. The rung sets
  where that fact sits: in the question at junior, in the system description
  at senior, and in a scenario where both pieces carry a real cost at
  principal_engineer. Any difference other than the tested principle is a
  defect, so the guidance asks for surface parity. No scaffold and no
  teaching note, since either would point at the answer.

  **A/B order is the server's.** The provider returns `better_piece` and
  `other_piece`; the kind's `.arrange!` hook, which ingest calls on each
  resolved section after `.reject_unusable!`, rolls `POSITION_WEIGHTS`
  through `WeightedRoll`, writes `piece_a`/`piece_b`, sets
  `answer_key.better`, and deletes the canonical fields. There is no
  "must differ from the stored order" rule, which with two pieces would
  always swap. `.reject_unusable!` refuses a missing, blank or non-string
  piece, a piece past `MAX_PIECE_LINES` (24 non-blank lines), and an answer key missing any
  of `deciding_fact`, `principle`, `why_other_fails`. Specs pin the roll to
  B (`spec/support/weighted_roll_position_default.rb`), which sorts after
  `real_source_default.rb` on purpose. `script/report_answer_positions.rb`
  is the read-only check on A/B balance; no log line records a position.

  **The answer key never leaves the server before review.** `answer_key` is
  the kind's `.answer_key_fields`, so `without_answer_key` keeps it out of
  `[difficulty_diagnostics]`, `judge_section` keeps it from the judge, and
  `duck_section_context` gains only `piece_a` and `piece_b` (scenario and
  question were already there). The page shows the key, as "What decides
  it", only once the section has a review.

  **Answer storage.** `"pick:a\n" + reason` in the existing answer slot, as
  Parsons stores `"order:…"`. The kind owns `parse_answer`, `encode_answer`
  and `answered?`: a valid pick and a reason of at least
  `MIN_REASON_LENGTH` (40) characters. The form is a radio fieldset and a
  labelled textarea; an inline script in
  `responses/answers/_design_comparison` writes them into the hidden
  `data-field` textarea and sets its `data-answer-complete`, so the shared
  gate, progress and hint lock work unchanged. `review_context` decodes the
  answer ("Picked: B. Reason: …") and hands the grader the key; the grading
  note names the main point and essential pieces, caps a matching pick with
  a vague reason and the other pick with a sound reason at developing, and
  never restates the rubric's levels.

  **Vocabulary.** `.narrow_vocabulary` is an allowlist built from the
  existing constants (the code-smell, OO-design, module-design and
  domain-modeling groups, the data-modeling group minus `DEFERRED_CONCEPTS`,
  the TypeScript concepts, and the concepts in `HOSTED_CONCEPTS`),
  intersected with the day's language vocabulary, minus `TRADEOFF_CONCEPTS`
  unless the rung is principal_engineer. Concepts whose worse piece would be
  incorrect stay out. `missing_constraint`, `unsafe_migration` and
  `wrong_cardinality` were deferred after the 2026-10-01 real-draft check,
  where a missing_constraint draft's pieces behaved differently under the
  scenario's own concurrent writers and bulk insert and the judge kept it;
  each returns only after a comparison run shows behavior-equivalent
  drafts. The judge guidance names behavior that differs under any
  condition the scenario states as a reasoning failure. Callers that know the rung pass it (`generation_guidance_for`,
  `can_host?` through the prompt's per-kind rungs, the kind-difficulty
  diagnostics, `ladders_for`); `DailyPlan` passes none and gets the strictest
  list; `ConceptHosts` unions every rung unless handed a `difficulty`, which
  `LadderCoverage` passes so a targeted kind is read at its level. History
  records under the day's language bucket. Each concept-group guidance line
  for a group this kind hosts names its design_comparison idiom once;
  silent correctness and meta skill are not hosted, so their lines do not.

  **The judge solves it blind.** `.judge_solve_options` (`%w[a b]`) adds a
  required `better` field to this kind's verdict schema and to
  `JudgeVerdict.parse`, and `.judge_guidance` adds the kind's contract to the
  judge prompt. `JudgedGeneration` compares the solve with the key through
  `.solve_matches_key?` and logs `[judge_solve_mismatch] user=… section=…
  rung=…` with neither the key nor the pick; the outcome carries only
  `solve_matched`, one boolean per judged version. Rejecting on a mismatch
  below principal_engineer, as underdetermined, sits behind
  `JudgedGeneration::REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL`, which stays
  false until `script/compare_models.rb judge` has run on real drafts and a
  person has read the disagreements; principal_engineer never rejects on a
  mismatch. The judge may reword the title, scenario and question, which is
  where the deciding fact lives, so an edit to this kind is judged once more
  (`.rejudge_edits?`, true only here): if that judgment rejects, cannot
  answer, or solves the edited section against the key, the unedited draft
  ships and the outcome records `edit_reverted: true`. It costs one judge call
  only when this kind is edited, and `JUDGED_GENERATION_BUDGET` adds one
  judge call's worst case for it. Because the solve makes the judge's own words an answer
  candidate, this kind's outcomes omit evidence and reason, its reply is
  parsed with `log_raw: false`, and an unreadable response body that starts
  like JSON is logged by size only, for every call. Known limit: the judge
  sees one section, so it cannot check that a shared concept's comparison
  avoids the code review's scenario. Its guidance asks only what it can
  check inside the section: a section that restates a defect to find,
  rather than offering a choice between two working designs, is a
  scope_mismatch.

  **The reference stays closed.** A concept's reference opens on its own on
  first exposure for every other kind; for this one it names and illustrates
  the principle the grade asks for, so `.reference_opens_before_answer?` is
  false and it stays closed until the engineer opens it.

  **Setup.** The Exercise mix groups the fixed kinds under "In every set"
  (difficulty only), and gives pattern a group of its own.

- **Two-stage generation**: the weekday batch drafts a set, then reads each
  section back and decides keep, edit or reject
  (`AiService#generate_judged_exercise`, which delegates everything after the
  draft to `JudgedGeneration`). It exists because two real sections
  shipped broken in the same way. A `code_review` planted on a Ruby `Thread`
  needed the engineer to know how threads behave, and a game-flavored one
  needed to know that render loops are hardware-dependent. In both the missing
  knowledge was not the tagged concept, so `ConceptReference` — which explains
  only the tagged concept — had nothing to offer, and the section was
  unanswerable for a reason no downstream check could see.

  **Every weekday first generation, not regeneration.** Judging costs a
  second provider call per section and a possible third for a retry.
  `GenerateDailyExercisesJob#generate_for(user, judge:)` passes `judge: true`
  from the cron branch and, on a weekday, from the on-demand branch too. It
  was cron-only at first, but a user who opened the dashboard before their
  8am tick got an on-demand set, and the batch then found the day filled, so
  an early riser was rarely judged. The cost of the change is a longer
  spinner on the dashboard, which is why `dashboard/_generating` polls for
  `AiService::JUDGED_GENERATION_BUDGET` rather than the draft's budget alone.
  A weekend "generate anyway" set and `RegenerateExerciseJob` stay on
  `#generate_exercise`, the single-stage path, which is unchanged.

  **The judge classifies; it never writes a second draft.**
  `JUDGE_SYSTEM_PROMPT` states the principle it turns on: "A question may be
  difficult, unfamiliar, or conceptually demanding. Its difficulty must come
  from the intended reasoning task, not from unclear wording, missing
  information, or accidental prerequisites … Never reject a problem for being
  hard." It may rewrite prose fields and nothing else — never code, schema,
  options, blocks, the tagged concept, the kind, or any field carrying the
  planted defect — and it is told not to change the task or the pitch. A
  creative second pass would be a second generator, with a second set of
  failures nothing checks.

  **Each kind states its own task**, so the judge measures a giveaway against
  something concrete rather than a general idea of fairness:
  `ExerciseSection.judge_task` is the one-sentence task (abstract on the base
  class, so a new kind fails loudly rather than shipping unjudged),
  `.discovery?` marks the kinds whose task is to find something hidden
  (`code_review`, `design_comparison`, `security_review`, `plan_review`,
  `parsons_problem`), and
  `.prose_fields` bounds what may be rewritten. A kind whose task is to name
  the concept is not rejected for naming it: the prompt says so outright, and
  "What vulnerability exists in this endpoint?" is the intended framing for a
  security review.

  **Every deterministic check lives at the boundary, in `JudgeVerdict`.**
  `STATUSES`, `ISSUE_TYPES` and `PRINCIPLES` are closed lists;
  `.parse` refuses a status, issue type or principle outside them, a rewritten
  field that is not one of the kind's `prose_fields`, a field rewritten to
  blank, and evidence or a rejection reason that is missing, blank or not a
  string. Evidence is not matched against the section's text: nothing acts on
  it, and a verdict refused over a paraphrased or elided quote falls back to
  the draft, so a real rejection would ship the broken section it caught. It
  is there for a person reading the log. `#apply` merges the rewrite
  over the section, leaving the artifact untouched. Because the code checks
  all of that, the prompt states only the semantic judgments — the same split
  `ProblemSetIngest` applies to a problem set.

  **Concept history is deliberately not passed.** The judge sees one section,
  its concept, its rung and lock state, and the kind's task; no other section,
  no rationale, no history. That severs the channels a tier could leak
  through, and it costs something real: the judge cannot know what this user
  has met, so "unstated prerequisite" is judged against the rung's
  `KindDifficulty::LEVEL_DEFINITIONS` sentence rather than against the person.
  The app records nothing about incidental knowledge anyway — whether someone
  knows what a Thread is was never tracked — so there is no history that would
  have answered it.

  **A rejection buys a bounded number of retries, never an open-ended
  loop.** The count is a kind facet, `ExerciseSection.judge_retries`: 2 for
  a fixed kind (`fixed?`), since every day is built around it, and 1 for
  every other kind. `retry_section` regenerates
  that kind alone through the same builder and the same ingest —
  `build_exercise_prompt`'s `only:` restricts the kinds and the schema,
  `fixed_concept:` adds the line naming the concept the section must carry,
  and `ProblemSetIngest`'s `fixed_concepts:` enforces it through
  `enforce_fixed_concepts!` at the boundary. The concept is fixed because the
  plan placed it: a retry free to choose again could drop a due retention
  check. Each retry is judged again. Rejecting the last retry, or a retry
  generation that fails for any reason (`[judge_retry_failed]`), drops the
  section. The outcome's `retry_principle`, `retry_issues`, `retry_evidence`
  and `retry_reason` are lists with one entry per judged retry, in order.

  **A drop removes the key after ingest**, so no placeholder exists and every
  downstream count still derives from `active_section_keys`. The dropped keys
  persist on `daily_exercises.dropped_sections` (jsonb), and the dashboard
  says so in one muted line (`dashboard.section_left_out`), which is the only
  user-facing change. Every kind can be dropped, both fixed kinds included:
  with two of them, a day without one is still a day. A day whose sections
  are all dropped raises `AiService::AllSectionsRejectedError`, which
  `GenerateDailyExercisesJob` records through `persist_failure` like any
  other failed generation, so no empty day is ever written. Before both
  fixed kinds existed, a twice-rejected `code_review` shipped with
  `fallback: anchor` and an `anchored: true` stamp. Nothing writes that
  stamp now; older rows keep it harmlessly, and it stays in
  `ProblemSetIngest::SERVER_STAMPS` so a provider cannot forge it.

  **The rotation trade is stated rather than compensated for.** A dropped
  section still reads as scheduled: `User#recent_exercise_history` puts the
  dropped keys back into `section_keys`, so `SectionRotation` sees the kind as
  shown and its staleness does not grow from a delivery failure.
  `ExerciseHistoryEntry#dropped` is added to the answered count in
  `SectionCount`'s mean, but a day's credit never exceeds the sections it
  delivered (`active_section_keys`), so a drop cannot count as finishing
  sections the engineer never saw. That cap means a drop can still shorten
  tomorrow: three planned four-section days that each delivered two sections
  contribute at most two apiece, so the next day gets at most three sections.
  Within the cap, a drop fills in unanswered delivered sections, so on a day
  that lost one section, answering two of the three delivered counts the same
  as answering all three (#215). A day with nothing answered still earns
  zero, so a drop never turns an untouched day into finished work. This
  reverses the rule #215 shipped, which credited a drop only when every
  delivered section was answered: with two fixed kinds that can each be
  dropped, that rule let one rejected section shorten tomorrow. The cost of the rotation trade is the reverse
  of the loop it prevents: a kind the judge keeps rejecting can go unseen for
  a long time without the starvation guarantee noticing. Nothing in the
  rotation compensates, on purpose. The one exception is a two-section
  Automatic day, where the coverage exception reads delivered dates and so
  may add such a kind back, at most once in five weekdays. Drop rate per kind is read off the
  `[difficulty_diagnostics]` line's `judge:` entries, which are keyed by
  section key and carry `dropped: true`; rejection rate per principle comes
  off `principle` and the `retry_principle` list in the same entries, each
  with the `evidence` the judge quoted and the `reason` it gave, so a rate
  can be read back against the text it was about. A design comparison's
  entries carry no evidence or reason, for the reason its own bullet gives. That drop rate is
  the thing to watch, and `pattern` is the likely candidate, since its task is
  the least stated in the generation prompt.

  **Planned concepts a drop left unhosted are recorded and nothing is
  rescheduled.** The plan attributes a concept to a section only in the fourth
  slot, so `unhosted_concepts` decides after the fact the way `log_retention`
  already decides honored: the dropped section's own concept, matched against
  what the plan offered as a due check or as reinforcement. It can therefore
  never name a concept the plan did not offer. The `[retention]` line gains
  `dropped=key:concept`, so a due check tagged on a dropped section reads as
  offered rather than honored, and the diagnostics payload gains `unhosted:`.
  Each of the two `[retention]` lines names only its own track's drops: a
  dropped fourth-slot kind (`ExerciseSection.fourths`) goes on the fourth
  bucket's line, and every other dropped kind on the language line.

  **A judge failure never costs the day its set.** When `judge_section`
  raises, times out, or returns output `JudgeVerdict` refuses, the draft
  section stands unedited, `fallback` records the reason from
  `AiService.judge_fallback_reason` (`invalid_output`, `truncated`,
  `invalid_json`, `refusal`, `timeout`, or the shared error code), and
  `[judge_fallback]` warns. The judge is never retried. The review prose
  judge reads the same table, so the two judges' fallback rates compare.

  **The judge's reply is held to a schema on Claude.** Its call is capped, so
  it runs with thinking off, and with nowhere else to reason the model once
  wrote its checks out as prose and never reached the JSON. `judge_section`
  passes `JudgeVerdict.schema_for(kind)` as `response_schema:`, and
  `ClaudeService` sends it as structured output (`output_config.format`), so
  the API only lets the model return one of the three verdict shapes. A
  prefilled `{` was the other option; every model `ClaudeService` routes to
  rejects a prefill with a 400. The schema is built from the same closed
  lists `.parse` checks, and `.parse` stays the boundary, since the schema
  cannot bound string length. `GeminiService` accepts the keyword and does not
  send it yet (#228), so a Gemini judge reply is held only by its prompt.
  `OpenaiService` answers the keyword with JSON mode (`text.format:
  json_object`) rather than the schema: OpenAI's strict schemas need an object
  at the root and every property required, and `VerdictSchema` builds an
  `anyOf` with optional fields. JSON mode guarantees a parseable reply, and
  `.parse` holds the shape.
  `response_schema:` is the fourth additive keyword on `#call`, after
  `cache_system:`, `max_tokens:` and `history:`; `judge_section` and
  `judge_review_prose` (`ReviewProseVerdict.schema`) pass it, and every other
  caller omits it.
  `single_attempt:` is the fifth: the review prose judge sets it, and every
  other caller omits it.

  **Known leak, reported and left.** The reference disclosure above a section
  is titled "Reference — <concept>: how it works", which on a discovery kind
  names what to find before the engineer looks. It is the same leak the judge
  is told never to flag, because the label already exists outside the section.
  Fixing it means a neutral summary until the section is answered, which is a
  change to the reference, not to generation.

  **Cost and latency are estimates.** Against an Opus 5.5 draft and a Sonnet 5
  judge on a four-section day, the draft is roughly $0.15-0.23; judging adds
  about $0.03, and one retry with its re-judge about $0.07 more — under a
  fifth of a normal day, and Haiku would halve the judge's share. Worst case
  runs about 55-155 seconds on top of the draft for one retry cycle (judge
  fan-out 5-15s, retry 15-40s, re-judge 5-10s), plus about 20-50 seconds and
  $0.07 when a fixed kind needs its second retry, and stays there however
  many sections were rejected: the retries fan out the same way the judging
  does, so the day waits for the slowest rather than their sum.
  `JUDGED_GENERATION_BUDGET`, which the dashboard's generating poll reads,
  derives its retry cycles from the largest registered `judge_retries`, each
  cycle `worst_case_call_seconds(RETRY_READ_TIMEOUT)` plus
  `worst_case_call_seconds(READ_TIMEOUT)`, plus one judge call when a kind
  re-judges its edits. Each retry asks for one
  section, so it runs on `RETRY_READ_TIMEOUT` rather than the draft's
  300-second budget. Both figures assume that token
  shape and that list price; re-measure against `ApiUsage` rows under
  `purpose: "judge_section"` rather than re-deriving them.

  **Stage 1 never carried `PLAIN_LANGUAGE_STANDARD`.** The standard is
  interpolated into the duck, alternates, follow-up, grading, concept
  reference and recognition guide prompts, and into neither `build_system_prompt` nor
  `build_exercise_prompt`. `JUDGE_SYSTEM_PROMPT` does carry it, which is the
  point: the judge rewrites prose, so the standard sits where the rewriting
  happens. So nothing was removed from the draft prompt to
  make room for the judge: the field bounds it does carry define the artifact
  or are enforced by ingest, and they stay. Prose quality is the judge's job
  by assignment, not by subtraction.

  **The judge is shown the section, not how it was made.** `judge_section`
  strips the answer key and every `ProblemSetIngest::SERVER_STAMPS` field, so
  it never learns the day eased this section, which real file grounded it, or
  that an earlier verdict rejected it. `current_schema` is deliberately not
  stripped: it is on the engineer's screen, and answerability depends on it.
  The rung and lock state reach the judge as stated arguments instead, since
  a level is what it measures against. `JUDGE_SYSTEM_PROMPT` enumerates the
  rejection principles and issue types from `JudgeVerdict`'s own constants
  rather than restating them, so the prompt cannot offer a verdict the
  boundary would refuse.
- **Scenario flavor**: the business setting every section's `scenario` is dressed
  in comes from one prompt line, and that line offers one pool from
  `AiService::SCENARIO_POOLS`. Most days choose between two: the general,
  job-adjacent `SCENARIO_DOMAINS` and `GAME_AND_ANIMATION_SCENARIO_DOMAINS` — a platformer's save-state store,
  a level editor's undo stack, an animation timeline's keyframe editor.
  `DailyPlan` rolls which pool once per day (`SCENARIO_FLAVOR_WEIGHTS`, 70%
  game and animation) and carries it on `Result#scenario_flavor`; the prompt
  renders the chosen pool and the diagnostics log records the flavor. Nothing
  persists it, like `code_review_mode`. A prompt-stated "roughly 7 in 10" was
  rejected for the reason `CODE_REVIEW_MODE_WEIGHTS` records: nothing would
  decide or record it. The 30% is a floor, not a placeholder — an exclusive
  pool relocates the staleness this fixes into a smaller fixed pool, and a
  familiar setting starts to predict the bug.

  **A beginner gets everyday settings instead of job-adjacent ones.**
  `DailyPlan::SCENARIO_FLAVOR_WEIGHTS_BY_SKILL_LEVEL` gives `beginner` 70%
  `EVERYDAY_SCENARIO_DOMAINS` (a shared grocery list, a gym workout log, a
  library checkout) and 30% game and animation, and never the general pool:
  webhooks, tenants and invoice runs assume someone already works in
  software, which a career changer does not. Every other skill level keeps the
  default weights. The everyday pool's own rule asks for plain words with no
  back-office terms, and it carries no legacy GraphQL clause, the one piece of
  industry framing the other two pools share. It is keyed on skill level, a
  difficulty setting, because generation never reads learning-track state;
  joining the junior track is what sets beginner. A spec holds the pool's
  entries clear of back-office words, as it holds the game pool clear of
  game internals.

  **Flavor is setting only, never a source of concepts.** The tagged concept
  and the planted issue still come from each section's own vocabulary, and
  the game-day line says solving a section must never require knowing how
  games or animation work inside. That rule is the lesson of a real trial: a
  `code_review` planted on frame-rate-coupled velocity failed because the fix
  needed a domain fact (render loops are hardware-dependent) rather than
  reasoning from the code, and `ConceptReference` explains only the tagged
  concept, so nothing could have supplied it. A spec holds the pool's entries
  to naming systems, not internals. Every kind reads the same line —
  `architecture`, `plan_review` and `pseudocode_to_code` have no separate
  mechanism — except `ambiguity_hunt`, whose own schema fragment keeps its
  scenario a Code Gym-style feature request: an unfamiliar setting would add
  a second thing to work out before the ambiguity, the burden that kind exists
  to remove. On a `RealSource` day `ProblemSetIngest` stamps the server's own
  `scenario` over `code_review`, so that field always names the real file.
  The snippet's comments, names and prose are not guaranteed: each excerpt's
  `#instruction` (`RealSource::Excerpt#setting_rule`) tells the model the
  flavor line does not apply and to describe Code Gym, never a game or other
  fictional domain. That is prompt guidance, and nothing downstream checks a
  snippet's wording (#171).

  **Grounded sections remain eligible for retention checks.** The same
  `setting_rule` gives the excerpt's source-specific instructions precedence
  over the general variety, mastery-loop, and retention requests for new
  domains, names, or framing (#175). The method keeps its real names; a
  migration keeps its real tables and may still be a plausible next migration.
  Freshness means a fresh application of the chosen concept in the planted
  flaw, with concept eligibility and difficulty unchanged. Other sections
  still follow the general freshness rules.

  **Accepted limitation:** `RealSource.pick` prefers never-seen excerpts, then
  the least recently seen, but this is not concept-specific novelty tracking.
  An excerpt can recur, and `recent_performance` supplies its scenario, not
  its prior planted flaw. The prompt asks for a fresh application; neither
  the picker nor ingest proves it is fresh or that it measures retention.
  Excluding grounded sections from retention would reduce available hosts;
  requiring an unseen excerpt would need a separate eligibility policy.
  Neither scheduling change is part of this fix.
- **Meta-skill concepts**: `AiService::META_SKILL_CONCEPTS` (`reading_for_intent`, `spotting_unstated_assumptions`, `separating_symptom_from_cause`) name reasoning skills rather than technical topics, so `ConceptReference` delivers "how to think about this" on a real problem instead of on a tips page. They sit in both `RAILS_CONCEPTS` and `JS_CONCEPTS` like the data-modeling concepts, and for a structural reason rather than a preference: `ConceptBucket` dispatches on section key and never on concept, so a bucket of their own would require a section kind. Per-language mastery is the accepted cost; being outside `LANGUAGE_AGNOSTIC_VOCABULARIES` is the gain, since their reference then shows real code. Their hosts are `code_review` (non-schema modes), `pattern`, and `challenge` — every other kind draws a disjoint vocabulary and is excluded without an exclusion being written, and `parsons_problem` excludes them explicitly (`excluded_vocabulary_keys`) because a sequencing format has nothing to read. Because these are fuzzier than `n_plus_one`, `AiService#meta_skill_framing_guidance` adds one prompt line — stated once for all sections, named from the constant — requiring the section to still contain one findable issue that the concept only *frames*. Their hosts' grading notes name a planted issue or stated requirement as the main point, and grading needs something missable to have been there. `AiService#can_host?` (given the concept, section key, and the day's generation language) derives third-slot retention hosting from `ProblemSetIngest.selectable_vocabulary_for` rather than restating it, so this exclusion — and the data-modeling one — is correct by construction rather than by coincidence.
- **Alternate framings of a concept reference**: `ConceptReference` auto-expands
  on a concept's true first exposure so a beginner has a foothold before
  attempting anything — but it is one auto-generated explanation with no
  fallback, and if it doesn't land there is nowhere to go. A low-weight control
  *inside the disclosure* asks
  `ConceptReferencesController#explain_differently` for the same concept
  explained another way, capped at
  `MAX_ALTERNATES_PER_CONCEPT`. The duck is deliberately not the answer to this:
  `DUCK_SYSTEM_PROMPT`'s explain mode is scoped to "Describe only what is
  already on their screen", which is describing a problem rather than
  re-teaching a concept from zero, and that scoping is intentional.

  **Nothing is persisted** — not a row, not a column. The framings live in the
  tab that asked for them, exactly as the duck thread's turns do, and the cap is
  the same soft, request-level kind for the same reason (each user spends their
  own key). The shared `ConceptReference` row is read and never written, so one
  engineer asking for another angle cannot change what a teammate reads.
  Storing per user was considered and rejected as heavier than the value;
  storing on the reference itself would have made the cap a race between
  teammates and enlarged the cached artifact everyone reads. Accepted cost: a
  framing is gone on reload, and meeting the concept again next week costs
  another call.

  **The safety property is the signature, not the prompt.**
  `#explain_differently` has no "don't hint at the answer" rule and needs none —
  it only ever runs post-review. This surface runs *before* a day is submitted,
  so `AiService#explain_concept_differently(user, reference, prior_alternates:)`
  is handed no exercise, no response and no section: it cannot reach today's
  problem because today's problem is never passed in, the same guarantee
  `#generate_concept_reference` and `#assess_difficulty` carry. A prompt line
  restates it; the signature is what holds it, and a spec pins the parameter
  list.

  **Why not a teach-then-practice rotation** (considered, rejected): apps that
  gate practice behind a lesson step do it mainly because immediate recall of
  just-read material creates an illusion of competence — it feels like learning
  but transfers worse than spaced, effortful retrieval. This app's model
  (attempt first, reference available immediately, the concept resurfacing later
  in a different framing via the mastery loop) is the better-evidenced one. The
  single legitimate reason to front-load teaching — a true beginner has zero
  foothold — is already covered by the first-exposure auto-expand, and
  difficulty-adapts-to-experience is already live through mastery tiers and
  scaffold fade. It just isn't branded as a visible "rotation", consistent with
  tier state staying invisible everywhere else here.
- **The fourth slot**: an optional fourth `problem_set` key, alongside `code_review`/`design_comparison`/`pattern`/the rotating third — `DailyPlan::NO_FOURTH_TRACK` lets a day give it up entirely, and `AiService#fourth_reinforcement_line` reads as nil-able rather than assuming the key is always present. When present, `SectionRotation` picks one of `ExerciseSection.fourths`: `plan_review` (review a flawed implementation plan), `ambiguity_hunt` (list what needs clarifying about a vague feature request) or `pseudocode_to_code`. Each has its own closed vocabulary (`AiService::PLAN_REVIEW_CONCEPTS` / `AMBIGUITY_HUNT_CONCEPTS` / `PSEUDOCODE_TO_CODE_CONCEPTS`) and its own `ConceptBucket` — language-independent, like `architecture`, so its mastery/reinforcement history never mixes with a programming-language bucket. `DailyPlan#for` decides the fourth slot's kind and its reinforcement/retention state on a track fully independent of the three-slot one, since the vocabularies can never mix. The slot holds exactly one concept (`DailyPlan::FOURTH_SLOT_CAPACITY`), so reinforcement is truncated to one and gives the slot up entirely when an overdue retention check claims it — never both. `ambiguity_hunt` also returns a hidden `planted_ambiguities` list — the answer key for grading coverage — which must never reach the rendered page, a pre-submission AI context (e.g. the duck thread), or log storage (`AiService#without_answer_key` strips it from the difficulty-diagnostics payload, the one place a whole `problem_set` is serialized); `plan_review`/`ambiguity_hunt`'s `plan_excerpt`/`request` fields are visible on screen and so are safe to include there. Since coverage grading has no meaning without that list, `ExerciseSection::AmbiguityHunt.reject_unusable!` validates it at the provider boundary and refuses the section when no usable entry came back — but only when `ambiguity_hunt` actually won the fourth slot, since an answer key nothing downstream will read is no reason to refuse anything. It is one of the per-kind boundary checks that refuse rather than repair (`PseudocodeToCode` refuses an unusable `problem_statement`, `DesignComparison` an unusable piece or answer key). A refusal costs only that section: `ProblemSetIngest` leaves the section's whole slot out of the set and reports it on `Result#unusable_sections` (key, concept when it is in the section's vocabulary, and the check's message), and raises `InvalidResponseError` only when nothing usable remains or a requested key is missing entirely. `AiService` logs `[unusable_section] user= section= reason=` with the check's message only. The judged path treats a planned unusable section as a rejection the judge never saw — the kind's retries with its drafted concept fixed, none without a concept, then a drop — and the single-stage path (`generate_unjudged_exercise`, used by weekend generation and `RegenerateExerciseJob`) drops it and records it in `dropped_sections`. Which fields are answer key is a kind facet too, `.answer_key_fields`, and `ExerciseSection.all_answer_key_fields` is the union every strip site reads. A *wrong count* is not a failure: `ExerciseSection::AmbiguityHunt::PLANTED_COUNT` is the generator's target, but nothing downstream reads it (the review prompt lists the ambiguities, never counts them), so a short list still grades and refusing it would cost the section over the likeliest deviation an LLM makes on a counted list. Long lists are truncated to `ExerciseSection::AmbiguityHunt::MAX_PLANTED`.
- **Which sections count**: `DailyExercise#active_section_keys` — code_review and design_comparison plus whichever of pattern/third/fourth today's plan chose, precedence-resolved for third and fourth, and never more than `MAX_SECTIONS` — is the single authority for "how many sections does this day have." It delegates to `ExerciseSection.resolved_keys`, which derives the answer from `ExerciseSection.slots` and is what `ProblemSetIngest` reads for a payload that is not a row yet. A day holds 2 to `ExerciseSection::MAX_SECTIONS` (4) sections, or fewer on a judged day where sections were dropped; `DaySize` (with `CoverageException`) and `SectionRotation` decide how many and which, but `active_section_keys` is still the one place anything downstream reads the answer. Every denominator (progress bar, `completeness`, history's count, the generation prompt's history line), the numerator (`DailyResponse#answered_sections`, via `DailyResponse#section_keys`), the submit gate, the answer/rating param slices, the duck-thread section guard, and the review fan-out derive from it. Never `problem_set.keys`, and never `answers.keys`: a payload can hold more third- or fourth-shaped keys than the page renders (`FakeService` answers with every kind deliberately, and a provider can return an extra alternate), and a regenerated day can leave an answer behind for a section it no longer presents — counting either reports a section count the page never showed. `active_section_keys` is unchanged by two-stage generation — it reads the delivered set, and a judged day's dropped key is gone from it. `DailyExercise#dropped_sections` is what makes a short judged day distinguishable from a short planned one: the day's shape is in `active_section_keys`, and why it is that shape is in the drop list beside it.
- **Section kind weight preferences**: a user's stated multiplier
  (`KindPreferences::MULTIPLIERS`, x0.25..x4, default x1) leans
  `SectionRotation#pick_kind`'s weighted roll and nothing else — it is applied
  only inside the branch the starvation guarantee returns before reaching, so
  a low weight can shrink a kind's odds but can never starve it. Exclusion is a
  separate, stronger action: it removes a kind from the pool everywhere the
  pool is read, including `slot_staleness`, and it is the only preference that
  can keep a starved kind out. Weights deliberately do not touch
  `slot_staleness` — that computation is a `max` over the pool deciding which
  *slot* wins a scarce spot, and a kind a weight could never actually place
  there would let a slot win on strength it can't back up; only exclusion,
  which really can remove a kind from contention, is allowed to move that max.
  User validation refuses an exclusion that would empty a slot, so
  `SectionRotation` never has to render a slot with nothing eligible in it.
  Storage is sparse — a kind left at the default multiplier stores no key at
  all — so a user who has never touched either control is byte-identical to
  pre-feature behavior.

  **Accepted consequence: excluding kinds also makes that slot fill less
  often**, not merely fill differently. `slot_staleness` is a `max` over the
  eligible pool, so a narrowed pool keeps the surviving kind scheduled — and
  therefore fresh — which lowers the slot's staleness and loses it ranking
  contests on days too short to fill every slot. Excluding two of the three
  fourth kinds takes that slot from roughly 81% of 3-section days to 50%, and
  from 36% of 2-section days to 14%. The exclusion copy says so outright rather
  than leaving it to be discovered. Ranking the slot over the *full* pool
  instead was considered and is worse: an excluded kind is never scheduled, so
  its staleness grows without bound and the slot would monopolize every scarce
  spot forever. Decoupling slot frequency from pool size needs slots ranked by
  when the slot itself last filled, which is a change to how every day is
  shaped and not something this preference should drag in behind it.
- **Difficulty targets and locks**: a user may set any section kind — code_review and pattern included, since a level needs no alternative candidate — to `junior` / `senior` / `principal_engineer` (`KindDifficulty::LEVELS`, deliberately disjoint from `skill_level`). Unset follows `skill_level`; a target replaces it as that section's baseline, with tier annotations and rating adjustments still applying on top; a lock suppresses the `(reduced)` easing rule and both rating adjustments for that section, with no exceptions, including a concept's first exposure. That last part is a deliberate tradeoff: a kind locked at `principal_engineer` can present an unfamiliar concept at full difficulty on day one. Lock changes prompt text only — `DailyPlan`, `ConceptMastery` and `User#concepts_*` never read `KindDifficulty`, and specs pin it — so unlocking reads current evidence. The block is appended by `AiService#kind_difficulty_guidance`, grouped by level, and grounded by per-concept ladder rungs written in the same `#generate_concept_reference` call as the reference and guide. A retention check in a targeted section is pitched at that section's level; raising a target after mastery makes the next check harder than the evidence behind it, an accepted consequence. `LadderCoverage` answers how grounded each kind is; `POST /learn/prepare_ladders` rewrites the ungrounded concepts behind a user's targets, the one scoped exception to the Learn tab's no-bulk-rewrite rule, and since `ConceptReference` is shared, that rewrite reaches every teammate. Weights and difficulty share `section_kind_preferences_version`, so a stale tab is refused whichever half it touched.
- **Drills**: a user can mark one concept, or a whole Learn display group, as
  drilled from the Learn tab (`ConceptDrills`, `ConceptDrillsController`). A
  drilled concept leads `User#concepts_needing_reinforcement`, and since
  `DailyPlan` truncates that list to today's hosts and order is priority, that
  is the entire boost: no second weighting mechanism, and `SectionRotation`,
  weights and `KindDifficulty` are untouched. It is the third axis of user
  control beside those two — which kind, how hard, and now which concept — and
  it is kept as separate from them as they are from each other. The prompt
  renders the entry as `concept (tier, drilled)` and one line says `drilled`
  never eases or raises anything; the locked-kind line already overrides
  easing "whichever concept they carry", so a drilled concept in a locked
  section composes with no special case.

  **Storage is two nullable columns on `ConceptMastery`** (`drilled_at`,
  `drill_group`), since that is already the one row per (user, concept,
  bucket); drilling a never-met concept creates the row in its untouched
  state, and every other reader ignores a row with no evidence. A group drill
  is one row per concept labelled with the group, not a group flag: clearing
  stays per concept, and the label is what lets the cap count a half-cleared
  group as one drill. Drilled concepts beyond today's capacity rotate
  never-seen first, then least recently seen, read from the exposure index —
  which drill was offered is never recorded, like every other offer.

  **A drill clears on the existing mastery signal and nothing else.** The
  same co-favorable rating that sets a row to standard in
  `ConceptMastery.evaluate_concept!` — self-rating "right level" or "too easy"
  AND AI "solid" or "strong", on one occurrence — also clears the drill. That
  can be a single day, and no drill-specific count exists on purpose: the
  retention schedule takes over from there exactly as it does for any
  mastered concept.

  **The cap is `ConceptDrills::MAX_CONCURRENT`, counted in drills where a
  group is one.** It is a stated 2, kept below the non-fourth hosts on the
  fullest day, where every drill but a fourth-bucket one competes, so
  single-concept drills always leave a host for evidence-driven
  reinforcement or an overdue retention check. It is not derived from
  `ExerciseSection.slots`: the second fixed slot raised that count without
  making a day longer, and `DailyPlan.share_hosts` already keeps a host for
  evidence when drills outnumber the hosts. A fourth-bucket drill counts
  against the same cap while occupying only the fourth: the cap bounds how
  many gaps are worked at once, not how many hosts they take. The reasoning
  sits beside the constant, a spec pins the value, and
  `ConceptDrills#can_start?` / `#can_start_group?` are the one statement of
  what it allows, read by the start methods and by the pages that offer the
  button.

  **Drills are scoped to what today can tag, and stand a retention check
  down.** `DailyPlan` hands `concepts_needing_reinforcement` a `hostable:`
  test built from the day's non-fourth kinds and `code_review` mode through
  `DayHosts`, which reads `ProblemSetIngest.selectable_vocabulary_for`, the same authority
  `AiService#can_host?` reads for retention checks — so a drilled
  architecture concept is offered only on an architecture day and a drilled
  data-modeling concept only when some section can tag it. A history entry
  ages out, but a drill persists until mastered and would otherwise claim a
  slot every day no section could carry it. When evidence-driven
  reinforcement is waiting, drills keep all but one host
  (`DailyPlan.share_hosts`), so a group drill larger than the day cannot
  starve the concept the ratings flagged; a one-host day still goes to the
  drill. A drilled concept whose retention
  check is due is listed once, as reinforcement, and its overdue check
  neither reserves nor takes a slot: the check would have asked for the same
  concept under a second instruction in the same prompt.

  **`ConceptDrills.for` reads only the user's current slice**
  (`ConceptBucket.slice_for`, shared with the Learn tab), so a drill stranded
  by a language change or a renamed concept neither counts against the cap
  nor sits unreachable behind a stop control the slice would 404. A concept
  whose group is drilled joins that group when drilled alone, a group absorbs
  lone drills of its own members, and a member stops as its group, so one gap
  is never two entries and a group is never half-labelled.

  **Drilling a paused concept from its own page ends the pause**, through
  the same exit an expired cooldown takes (`ConceptMastery#end_pause`), and
  that page says so before the click — the one deliberate look at tier state
  on the Learn tab, since a silent override would be worse than naming it. A
  group drill states no such thing, so it leaves a paused member paused and
  picks it up when the cooldown ends. A concept that reaches the paused tier
  while drilled keeps its drill but waits out the cooldown; `concepts_needing_reinforcement` skips paused rows whether
  drilled or not, and the page says it is waiting.
- **Each section records the rung it was pitched at**: `ProblemSetIngest`
  stamps `pitched_at` (`junior` / `senior` / `principal_engineer`) into every
  section the provider returned, not only the ones the day asked for, because
  the rendered set is resolved by slot precedence over what came back and an
  unrequested section can win. Server-owned like `scenario` and
  `current_schema`: every provider copy is stripped on every call, whatever
  the caller passed, before the stamps go on. The rung is
  `KindDifficulty#rung_for`: the kind's target when one is set, else the
  profile's skill level read through `KindDifficulty::RUNG_FOR_SKILL_LEVEL`
  (beginner and developing are junior, solid is senior, strong is principal),
  the one place that second scale is read as a rung. A section whose concept
  was offered as reduced-tier reinforcement in an unlocked kind also carries
  `eased: true`, since the prompt's `(reduced)` rule asked for an easier
  problem than the rung says; a locked kind exempts itself from that rule and
  so is never marked. That is the one easing the server decides. The prompt's
  "too hard" and "too easy" rating adjustments also move an unlocked
  section's pitch, and the model judges when they apply, so they are not
  recorded: an unlocked section's rung is what was asked for, possibly
  adjusted, and only a lock makes it exact. Provider copies of both stamps
  are stripped from every section first. A drilled concept at reduced tier is
  annotated `(reduced, drilled)`, and the prompt's easing rule names that form
  too, so its `eased` stamp records what was actually asked. `eased` reaches
  no prompt, the review or the duck. `pitched_at` reaches one: each graded
  section's review prompt states the rung it was pitched at, because the
  rubric rates against that level (see "Grading rubric"). The others build
  their text from named fields, and the judge, the one prompt that serializes a whole section,
  strips every `ProblemSetIngest::SERVER_STAMPS` field first. The
  diagnostics log serializes whole sections too and keeps the stamps, since
  it is read by a person rather than a model. The Progress page does read them, which
  is what they were written for: it says which rung a concept is held at from
  stored evidence rather than from the diagnostics log, where the pitch level
  lived before. Sections generated
  before this carry no stamp and contribute no evidence. No migration: both
  are keys inside the `problem_set` jsonb.
- **The Progress page shows the rung each concept is held at**, from the
  stamps above: `/progress`, a nav entry between Learn and History, in the buckets and
  groups Learn uses (`ConceptBucket.slice_for`, `ConceptGroup.grouped`),
  nothing regrouped; a single-group bucket shows one disclosure under the
  bucket's name, as Learn shows it flat. `RungLedger` is the one rule:
  for a concept, bucket and rung, the most recent day that answered a
  reviewed, un-eased section pitched at that rung; held when both ratings
  were favourable on every such section that day, the co-favourable and
  least-favourable-section rules `record_review!` applies, with a review that
  stored no rating counted as no signal as there; the standing
  is the highest held rung, which covers the rungs below, and a later poor
  attempt releases a rung, so the page describes now. It is pure over the
  response objects it is given and compares nothing to today, so time alone
  changes nothing, which a spec pins. A concept with no attempt is "not yet",
  or "not offered" when every kind that could show it is excluded, worded
  as the user's choice with a link to Setup; hosts come from `ConceptHosts`,
  the derivation `LadderCoverage` now reads too. Deliberately absent: any
  total across a bucket or the page (group bars only), the streak, tier
  state — the page shows rungs, not `ConceptMastery`, so the app's rule that
  tier stays invisible still holds — drills, and any control beyond
  navigation. No locked-kind marker, and no claim that a rung is exact: the
  ledger records what was asked, `eased` covers the one easing the server
  decides, and the page's own note says a rating adjustment can still nudge
  an unlocked section and only a lock makes a rung exact.
- **Skill level control**: Setup's "Skill level" select is the only page
  that edits `User#skill_level`, and it autosaves through `PATCH /profile`,
  which refuses a value outside `User::SKILL_LEVELS` with a 422. It sets the
  profile's prompt line, the rung of every kind without its own target
  (through `KindDifficulty::RUNG_FOR_SKILL_LEVEL`), and, for `beginner`, the
  scenario pools the day rolls from
  (`DailyPlan::SCENARIO_FLAVOR_WEIGHTS_BY_SKILL_LEVEL`). Joining the junior track
  sets it to `beginner`; nothing else changes it automatically, and daily
  ratings still nudge each set around it. It is not
  part of the Exercise mix, so it does not bump
  `section_kind_preferences_version`. No migration set a value: existing
  accounts keep the `developing` default until they choose otherwise, since a
  change here changes that account's prompts. The Exercise mix's default
  options name the stored value and are renamed in place once a save lands.
- **What a usage row records**: every provider call writes one `ApiUsage`
  row through `AiService#log_usage`, and that row now carries enough to price
  it. `model` is the model `#call` routed to (`MODEL_FOR_PURPOSE` /
  `DEFAULT_ROUTE`), so it matches those tables and any price list keyed the
  same way; the provider is not stored separately because the model name
  already says it. `cache_read_tokens` and `cache_write_tokens` are kept apart
  from `tokens_in` because Claude's `input_tokens` excludes both and each is
  billed at its own rate. On every provider, then, `tokens_in` is ordinary
  uncached input, excluding cache writes. OpenAI's `input_tokens` includes
  both `input_tokens_details.cached_tokens` and
  `input_tokens_details.cache_write_tokens`, so `OpenaiService` subtracts both
  and records them separately. Its routed models cache implicitly, regardless
  of `cache_system:`, and cache writes cost 1.25 times ordinary input;
  `cache_system: false` does not disable that provider default. OpenAI's
  `output_tokens` already includes reasoning. Gemini's `total_input_tokens` includes the cached part (a
  live repeat of a 14,199-token prompt reported `total_input_tokens` 14,199
  with `total_cached_tokens` 8,171), so `GeminiService` subtracts it; Gemini
  reports no cache write, so it records 0. Gemini's `tokens_out` is
  `total_output_tokens + total_thought_tokens`: its usage reports thinking
  apart from output (a live response gave `total_tokens` 736 = 25 input + 193
  output + 518 thought), and thinking is billed as output.
  Gemini rows from before this under-count output by however much the model
  thought and over-count input by whatever was cached, and every row from
  before this has a null model and null cache counts: unknown, not zero, and
  nothing backfills them, since a user's provider can change. Calls that fail
  before a response arrives still write no row.
- **How a cut-off reply is recognized**: each provider reports truncation as
  data and `AiService#call_and_log` decides it is fatal, after writing the
  usage row. Claude reads `stop_reason == "max_tokens"`. Gemini reads the
  interaction's `status == "incomplete"`, which the Interactions API defines
  as completed with incomplete results, hitting max_tokens being one example;
  token counts are not consulted, because a live call capped at 60 stopped at
  56 output tokens with that status and the old "output reached the cap" rule
  missed it (#243). Since that status does not say why the reply stopped, the
  error says the provider "did not finish its reply" rather than naming a
  limit. Uncapped Gemini calls are flagged too, as uncapped Claude calls
  already were. The thinking partner passes `allow_truncated: true`, so a
  partial reply is shown with an ellipsis, and an empty one still fails
  `text_or_raise`. A `failed` or `cancelled` Gemini interaction is not handled
  here. OpenAI accepts only `completed` or `incomplete` responses; any other
  status is an error, raised after usage recording even when partial prose
  is allowed. Its `incomplete` status is truncation unless the reason is
  `content_filter`, which is a refusal, as is a refusal content block.
  OpenAI authentication errors use fixed guidance and log only the HTTP
  status because the provider's error body can echo the key or its fragments.
- **Daily sections setting**: `User#daily_section_count` is Automatic (nil)
  or a fixed count in `User::DAILY_SECTION_COUNTS`, which runs from
  `SectionCount::FLOOR` to `ExerciseSection::MAX_SECTIONS`. Setup shows it as a
  radio group that autosaves through `PATCH /profile`. A fixed count is an
  override of the count only: `DaySize.for` returns it before completion or
  the gate is consulted, so no change to either can reach a user who chose
  one. Automatic takes the lower of the completion rule and the competency
  gate. `SectionRotation` still picks which optional kinds fill the day
  either way, since that is not sizing, and the gate still runs under a fixed
  count so the `[set_size]` line can log its evidence. Weights, exclusions, difficulty targets and locks are unaffected, and
  the setting is not part of the Exercise mix, so it does not bump
  `section_kind_preferences_version`.

  The lowest choice holds only the fixed kinds, and Setup's hint says so; a
  spec holds `SectionCount::FLOOR` equal to their number for that sentence. A
  fixed count is what the day is planned with, and the judge can still drop
  an optional section from it.

  **The boundary accepts only listed values.** `ProfileController` takes
  `User::AUTOMATIC_SECTION_COUNT` (`"automatic"`, stored as nil, and the value
  Setup's radio posts) or a listed count, as an Integer or its exact string.
  Anything else is a 422 that saves nothing, because Active Record's integer
  cast would turn `""` or `null` into nil, which means Automatic, `"abc"`
  into 0 and `"2.5"` into 2, and a JSON `2.0` equals 2. The model checks the
  same range only when the value changes, like the other validations that
  read moving constants, and `DaySize.for` clamps a stored count to the
  current range on read, so a row saved under a wider range plans a day the
  set can actually hold.

  **It replaced the `adaptive_set_size` boolean, and every account reads
  Automatic.** `AddDailySectionCountToUsers` adds the column with no default
  and no backfill, so an account that had turned adaptive sizing off, which
  meant a fixed full day, now gets Automatic sizing until it picks a count.
  That change was deliberate. The column was ignored for one release, while
  the old code kept serving through the pre-deploy migration, and
  `RemoveAdaptiveSetSizeFromUsers` dropped it afterwards.

  **A fixed count never gains a coverage section.** The coverage exception
  below applies only to Automatic, so under a fixed 2 a check that only an
  optional kind can host waits, and the `[retention] waiting=` line says so.
  A fixed choice wins by design.
- **What the plan did, on the row**: `daily_exercises.plan_notes` (jsonb,
  default `{}`, null false) records `{"size" => count, "size_reason" =>
  "setting" | "completion" | "gate" | "brake"}` on every plan, and
  `{"coverage" => kind_key, "coverage_reason" => "gap" | "due_check"}` and
  `{"shared_concept" => concept}`, each only when it applied
  (`DailyPlan::Result#notes`). The size is the planned count before any
  coverage addition, so a coverage day never reads as a larger planned size;
  `DailyExercise#planned_size` reads it and `.planned_size_before(date)` finds
  the latest earlier one. It is server-owned and written with the row
  from the plan that produced it, never recomputed while rendering: both
  generation paths hand it back on `AiService::JudgedSet#plan_notes`
  (`#generate_unjudged_exercise` on the single-stage path,
  `#generate_judged_exercise` on the judged one; `#generate_exercise` still
  returns only the set).
  `RegenerateExerciseJob` rewrites it from the new plan, clearing it when the
  new plan recorded nothing, and carry-forward moves it with the row because
  it is on the row. No backfill: no earlier plan added a section or shared a
  concept, and a row from before sizes were recorded has no `size`, which
  the transition log and the dashboard's size lines read as nothing to
  compare against.
- **Shared concept on a real struggle**: when reinforcement holds a
  reduced-tier concept, drilled or not, that every fixed kind can tag,
  `SharedConcept.pick` places the first such entry in both `code_review` and
  `design_comparison` (`DailyPlan::Result#shared_concept`). Reduced takes
  three stagnant reviews in a row, so it marks persistent difficulty; paused
  concepts never reach the list. Hosting goes through `DayHosts`, which reads
  the mode-aware `code_review` vocabulary and `design_comparison`'s strictest
  no-rung list, since `DailyPlan` never reads `KindDifficulty`; the cost is
  that a tradeoff concept is never shared. The pairing only fills hosts
  nothing else needed: reinforcement and retention are fitted first, against
  the final slot count, and the concept is shared only when every other
  reinforcement entry and due check can still take a distinct remaining kind
  able to tag it (`SharedConcept.placeable?`). A free section count alone
  is not enough: with architecture as the only optional kind, two Ruby
  concepts have the fixed sections as their only hosts, and pairing one
  would leave the other nowhere. So it never evicts a drill or another
  reinforcement entry, and when an overdue retention check takes the free
  host the day is planned exactly as it would be without pairing. This
  replaces the design note's "cut the remaining reinforcement by one more",
  which let a reduced concept push a drill out.

  **Advisory, like all reinforcement.** One line folded onto the end of the
  drilled-concepts bullet (`AiService#shared_concept_guidance`) names it for
  every fixed section, listing their keys from `ExerciseSection.fixed` and
  stating no count, so a day without
  one renders byte for byte as before; `DesignComparison.generation_guidance`
  already carries the kind's own rule (two working designs, a scenario
  different from the code review). A retry asks for one section and never
  carries the line. It is not enforced through `fixed_concepts:`, which
  would fail the whole draft when the model misplaced it. Each generation
  logs `[shared_concept] user=… concept=… reason=reduced_tier
  honored=true|false`, where honored means both delivered fixed sections
  took it (`ExerciseSection.fixed_sections_share?`). Within one review
  `record_review!` evaluates the concept once, on the least favourable
  rating, so the second angle makes leaving Reduced stricter and never adds
  weight.
- **Waiting retention checks**: `DailyPlan` reads due checks for every bucket
  in the user's slice, plus the bucket of the language being generated, in
  one query (`User#concepts_due_for_retention_check_in`), including
  architecture and the fourth buckets, which were fetched only when their
  kind was chosen and so waited with no trace on every other day. The
  generated language is added because a regeneration keeps the stored
  exercise's language, which can differ from the setting. That one read also feeds
  both tracks' retention checks, which filter it by bucket instead of
  querying each bucket again, and `ConceptMastery.due_for_retention_check`
  is the one statement of what "due" means. A check is selected, and a slot
  reserved for an overdue one, only when some section today can tag it, by
  the same `DayHosts` test the waiting classification uses: on a
  schema-review two-section day a core Ruby check that neither fixed section
  can tag waits as `no_host`, where the coverage exception can bring it a
  host, rather than being selected and then left out of the prompt. Each
  check the plan did not offer and reinforcement does not carry lands on
  `Result#waiting_checks` with a reason: `no_slot` when a section today
  could tag it but the hosts went elsewhere, `no_host` when none could.
  Generation logs them on one line beside the other two:
  `[retention] user=… date=… waiting=bucket:concept(no_slot|no_host),…`.
- **Coverage exception**: at two sections a day has no optional slot, so
  `SectionRotation`'s starvation guarantee has nothing to act on.
  `CoverageException` (pure) adds one optional section when the setting is
  Automatic, the day's count leaves no optional slot (`count <=
  ExerciseSection.fixed.size`), the struggle brake is
  off (`DaySize::Decision#brake?`, true while the gate's reason is `:brake`,
  even on a day completion alone would also have held at two), and no exercise dated on the previous `CAP_WEEKDAYS` (4)
  weekdays carries `plan_notes["coverage"]`. It picks (a) the kind able to
  host the most overdue waiting check at or past
  `ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER`, or else (b) the
  optional kind unseen for more than `GAP_WEEKDAYS` (20) weekdays, longest
  gap first, never seen before seen, ties in registry order. Both respect
  the user's exclusions, and (a) reads hosting through `DayHosts`. The added
  kind fills its own slot (`ExerciseSection.slot_for`) without weights, and
  `DailyPlan` decides the concept tracks again so the check can land in it.
  Reinforcement can still outrank that check for the one retention slot
  (`Addition#check` names the check, and `DailyPlan.check_landed?` reads the
  recomputed tracks for it); then the addition is given up and the day stays
  at two, rather than spending the cap on a section carrying something else.

  **The cap counts calendar weekdays, not delivered rows.** Weekends never
  count toward the four, a weekend addition inside the window still blocks,
  and a paused stretch counts as the weekdays it spans. Because the note is
  written at plan time, an addition whose section the judge dropped still
  counts. The checks run cheapest first: the setting and count cost
  nothing, then `History.recent_coverage_dates` reads the planned additions
  over the cap's window alone, and only a day the cap leaves open runs
  `History.for`, which reads each optional kind's last delivered date
  (`active_section_keys`) and the oldest date from one query over the last
  `HISTORY_LIMIT` (120) exercises before today. A
  kind never delivered counts as unseen from the oldest exercise read, so a
  new account gains nothing from the gap rule. Today's row is left out, so a
  regeneration plans as the first generation did. Generation logs
  `[coverage] user=… kind=… reason=gap|due_check`, and the diagnostics
  payload carries `coverage` and `shared_concept` beside the rest of
  `requested`.

  **What the dashboard says.** Two muted lines in the style of
  `dashboard.section_left_out`, on the unsubmitted dashboard. While the
  added kind is still in `active_section_keys`, `DailyExercise#coverage_shown`
  returns the stored `plan_notes["coverage_reason"]` and the line follows it:
  `dashboard.coverage_added.gap` ("a kind you haven't seen in a while") for a
  gap, and `dashboard.coverage_added.due_check` ("so an idea you learned
  earlier can come back up") for a due check, whose host may have been seen
  last week, so the gap wording would be false for it.
  `dashboard.shared_concept` shows only when both delivered fixed sections carry
  the planned concept (`#shared_concept_shown?`), so a dropped section or an
  ignored placement never produces a false claim. The shared line gives no
  reason: "because it has been giving you trouble" would expose the mastery
  tier, which stays invisible. It names the fixed sections from their
  locale names (`sections.<key>.name`, listed from `ExerciseSection.fixed`)
  and says "from different sides", so neither line nor prompt assumes how
  many fixed kinds there are.
- **Competency gate**: `CompetencyGate` decides how many sections an
  Automatic day may hold from reviewed work, and `DaySize` composes it with
  the completion rule and the Daily sections setting.

  **How a day is sized.** `DailyPlan.size_for` runs `CompetencyGate.for`
  once per plan, since it replays every post-rubric day, and hands
  `DaySize.for` plain values: the setting, `SectionCount.for(history)` and the
  gate's `Plan`. A fixed setting returns its count with reason `:setting` and
  ignores the gate, the brake and coverage. Automatic takes the lower of
  completion and the gate, clamped to `SectionCount::FLOOR..MAX_SECTIONS`,
  and names which bound decided: `:completion` whenever completion alone
  would give the same count, otherwise `:gate`, or `:brake` when the gate's
  reason is the brake. The coverage exception then adds at most one section
  as before, with `brake: DaySize::Decision#brake?`, so `CoverageException`
  keeps one caller (`DailyPlan.coverage_for`). The decision rides on
  `DailyPlan::Result#size`, and its count and reason go into `plan_notes`.
  `SectionCount` is the completion rule alone; `DaySize` owns a fixed
  setting's precedence.

  **Every account starts at two.** The gate reads rubric-stamped reviews
  only, so an account grows past two only as favourable, rubric-graded work
  accumulates, whatever its completion. A replay of the two active
  production accounts' history on 2026-10-01, under these constants, gave
  size 2 on every day: completion alone gives two, since about one section a
  day is answered, and earlier days had no stamped evidence to grow from.
  Every AI rating in that history predates the rubric, so the replay checked
  completion and self-ratings, not the AI bar. Raising `RUBRIC_VERSION`
  restarts every Automatic account at two the same way, since the gate then
  finds no review stamped with the new version. Specs follow the
  same start: a spec that answers an optional section asks for a full day,
  through `create_fake_provider_user(daily_section_count:)`, the setting, or
  by stubbing the gate open (`DailyPlanGateStubs` in `daily_plan_spec`),
  rather than relying on a new account getting four.

  **Logs.** `AiService#draft_exercise` logs `[set_size] user=… date=… {…}`
  as soon as the plan is decided, before the provider is contacted, so fixed
  settings, weekends, regeneration and attempts that later fail all leave
  one. Its JSON is `DaySize::Decision#diagnostics`: count, reason, setting,
  completion, and the gate's count, reason and evidence (`to_three` and
  `to_four` with required, available, `bar_met` and favourable counts and
  `by_kind`; the brake window; optional-day completion; levels). No
  answer-key field is in it. When the latest earlier row's planned size
  (`DailyExercise.planned_size_before`) differs, a second line records
  `[set_size] user=… from=… to=… reason=…`; it compares planned counts and
  never infers a change from the reason. The successful
  `[difficulty_diagnostics]` payload carries the same decision under
  `requested.size`, beside `coverage` and `shared_concept`.

  **What the dashboard says.** In the submitted state, on Automatic only,
  `SizeForecast` composes tomorrow's size through `DailyPlan.size_for` with
  today's submission in the completion history and today's review in the
  gate, and compares it with the size today's plan delivered: `plan_notes`'
  size plus one when it records a coverage addition
  (`DailyExercise#planned_size_with_coverage`), so a coverage day never
  promises a larger set of the size it already showed.
  `dashboard.size_change.larger` ("Your recent answers qualify you for a
  larger set.") shows when tomorrow's composed count is larger, so a gate
  increase that completion still blocks says nothing.
  `dashboard.size_change.smaller` names tomorrow's count, which
  `SizeForecast::Change` carries, and shows only when the brake is the
  reason and tomorrow is smaller. Neither shows for a fixed setting, which
  also skips the gate's query, for a day whose size came from a fixed
  setting (`size_reason` `setting`), since a switch to Automatic is not the
  engineer's answers, nor for a row with no recorded size. There is no score,
  tier or badge. The forecast adds the gate's query to each submitted-state
  load: timed at about 15 ms with 60 reviewed days and 58 ms with 250, it
  grows linearly with post-rubric history.

  **The rule.** The gate starts at two and folds over the user's reviewed
  days, oldest first. After each day: two `too_hard` self-ratings among the
  latest four results of any kind (`BRAKE`) return it to two; otherwise, at
  two, 4 favourable of the latest 5 fixed-kind results (`GROW_TO_THREE`)
  grow it to three; at three, 8 of the latest 10 (`GROW_TO_FOUR`) grow it to
  four, but only when the optional sections were all answered on each of the
  last `OPTIONAL_RUN` days that had any. Otherwise it holds. A window with
  fewer results than its size never meets its rule, and the gate moves at
  most one step a day. Favourable means an AI rating at or above `BAR`
  (`solid`) together with a favourable self-rating, the same co-favourable
  shape `RungLedger` uses, because the AI rating's level calibration is
  unverified. These values are a starting policy, not thresholds history
  has validated.

  **A brake restarts growth.** On every day the brake holds, the fixed-kind
  growth windows start empty, so growing again needs a full window of
  results that came after it. Without that, a user who struggles only on
  optional sections would swing from three to two and straight back to
  three on fixed-kind results earned before the struggle. The brake's own
  window is untouched, so the reason stays `:brake` while the too-hard
  results remain in it.

  **Eased sections reach the brake only.** An eased section answered an
  easier question than its rung, so its AI rating stays out of the growth
  windows, but its too-hard self-rating counts toward the brake: a struggle
  on a reduced-tier concept is the clearest one there is.

  **Levels come from the evidence, as of each day.** A kind's level is the
  `pitched_at` of its latest result so far, never today's target applied
  backwards. When it changes, that kind's earlier results leave the windows,
  even if it later returns to a level it held before. The earned count and
  other kinds' results stay, so a level change alone never takes back a size.
  Because the fold is pure and runs forward, adding a day cannot change how
  an earlier day was decided.

  **Evidence.** `ReviewedSectionResults` is the shared rule for which
  sections count: answered, graded from the closed rating list, and stamped
  with a rung. Eased sections are left out unless a caller asks for them,
  and each result says whether it was eased. It also states the rating
  rules the gate and `TrackGraduation` read: `at_or_above?` reads
  `ConceptMastery::AI_RATING_RANK`, `favourable?(bar:)` adds
  `DailyResponse::SELF_RATING_FAVORABLE`, and `too_hard?` reads
  `DailyResponse::SELF_RATING_UNFAVORABLE`. `TrackGraduation::Result` asks
  the same rules with `FAVOURABLE_BAR`, the lowest favourable rating, so its
  answers are unchanged, and `CompetencyGate::BAR` is that same constant.
  `ConceptMastery.record_review!` and `RungLedger` predate the class and
  still read the rating lists directly; folding them in is a separate
  change. A row whose
  review, answers, ratings or problem set is not a hash, or a section whose
  review is not one, is skipped rather than raised on, since the gate runs
  on every plan, fixed settings included. `TrackGraduation::Evidence`
  delegates to it with its 60-response cap and results unchanged (eased
  still left out), so generation code never names track code.
  `CompetencyGate::Evidence` asks it for eased sections too, requires the
  current `RUBRIC_VERSION` stamp, and reads every rubric-stamped day with no cap, in
  batches ordered by date and id. A cap would forget a size whose earning days
  had aged out; the batches bound memory, not history, so the query grows
  with post-rubric history. A day graded before the rubric adds neither
  results nor optional-section history. Each day reaches the fold as a
  `CompetencyGate::Day` whose `optional` is `:none`, `:incomplete` or
  `:complete`. The fold builds a `Plan`'s evidence (required, available,
  AI-bar and favourable counts, per-kind counts and levels) only for a plan a
  caller reads: `.plan` and `.for` return it for the last day, and `.plans`
  only with `evidence: true`. The `[set_size]` line logs it.
- **Pausing generation**: `User#paused_generation_at` (nullable timestamp; nil is active) suppresses only generation the user didn't ask for — the cron batch (`GenerateDailyExercisesJob`'s no-arg branch) and `DashboardController#show`'s auto-trigger. It never gates submitting or reviewing: `ResponsesController` has no pause check, so once a row exists for today the submit → review chain runs regardless of pause state or weekday. The toggle is `PATCH /account/toggle_generation` on the Account page — the one control for this column; a second one anywhere else would be a second pause mechanism. Each button posts the state it wants (`paused=0`/`1`) rather than asking for a flip, so a double-tapped Resume stays a resume instead of the second request re-reading an already-unpaused user and pausing it again; with no param posted the endpoint still flips, keeping its original contract. Days fully inside a pause create no `DailyExercise` row at all, so they are non-events to `User#recent_exercise_history` and `#current_streak` rather than skips. The one day that *does* leave a row is the day the pause began (or an explicit `/generate` while paused). **A set left unfinished when the pause began follows the user forward**: `DashboardController#show` calls `User#carry_held_set_forward!` on a day with no set, which re-dates the held, still-unsubmitted exercise — and the draft `DailyResponse` autosave left on it, which must move too or `#create` would build a second response for the same exercise — to `Date.current`, so the pause gives time to finish rather than hiding the set at midnight. Once it is submitted, `#held_exercise` finds nothing, the paused day stays empty and nothing generates, which is what the pause is for. `User#resume_generation!` performs the same recovery (`#recover_held_set`, shared) and then lifts the pause. The row lock also settles the race against a concurrent generation, and does it through the foreign key rather than directly: inserting today's exercise needs a FOR KEY SHARE lock on the same `users` row that `with_lock` holds FOR UPDATE, so a generator either committed before the lock (and the `exists?` check sees it) or blocks until after it and loses its own set to the unique index, which `GenerateDailyExercisesJob` already treats as "generated concurrently". Resume wins, which is the right way round — the held set carries the user's draft answers and a fresh one would not. The move locks the exercise, then its response, and writes in that order — the order `RegenerateExerciseJob` takes, so the two serialize but cannot deadlock — and re-reads the response under its lock, since `#held_exercise` read it outside any lock and a submit can commit in between; a submitted response ends the move, so a finished session keeps its day. It still sits in a SAVEPOINT catching both `RecordNotUnique` and a `date`-taken `RecordInvalid` (uniqueness is enforced twice, and the model validation raises first), so that were it ever to fail it rolls back only itself and the pause still lifts. Recovering the set also clears a same-day `last_generation_error`, since `/generate` is not pause-gated and a failed attempt while the held set sat at an earlier date would otherwise leave "Couldn't generate a new set" rendered above it — the banner `persist_failure` exists to avoid. The whole method runs in the user's own zone rather than the caller's, unlike the read-only history and streak readers, since it writes a date that has to be the user's today. That move both makes the set reachable (every "today's exercise" lookup is `for_date`, so at its original date it renders nowhere and `#create` 404s) and drops it out of both signals at once, since `recent_exercise_history` filters `date: ...Date.current` and `#current_streak` exempts today — no separate "exclude paused days" rule exists or is needed. Scoped to exercises dated on or after the pause, so a day abandoned *before* pausing stays abandoned; skipped entirely if an exercise already exists for today, so an explicit `/generate` while paused is never overwritten. Both regeneration columns clear on the move, because they describe the row's *day* rather than the set: `regenerated_at` would hide the Generate-new-set button behind a claim the dashboard states outright and that is no longer true ("You've already generated a new set today"), and a leftover `regenerating_since` is worse than cosmetic — `RegenerateExerciseJob` gates on `exercise&.regenerating_since` after resolving `for_date`, and re-checks that claim under the exercise row lock before it writes, by value rather than presence (the claim's timestamp is the worker's token, so a later click's claim is not mistaken for its own) — a claim `carry_forward` cleared mid-call means the generated set is discarded, and every release is guarded the same way, so a retry stranded from the pause day cannot replace the carried-forward `problem_set` or destroy the draft response the move preserved. **At most one set can ever be carried forward**, because `[user_id, date]` is unique — so a user who stranded several (paused Monday, clicked `/generate` on Tuesday, resumed Wednesday) gets the newest one back and the older ones stay where they are — **still breaking `#current_streak`**, not merely counting as skips: a past weekday holding an unsubmitted exercise hits that method's `exercised.include?(day)` break. Recovering one set does not repair a streak an older stray still zeroes. That is a limit of re-dating rather than a gap to close: two sets cannot both be today. Re-pausing does not move the floor `#held_exercise` searches from — `AccountsController` stamps a pause only when one isn't already running — so a second Pause cannot walk that floor past the set the first pause stranded. The same limit is why the move is skipped outright when today already holds an exercise. **Accepted consequence:** finishing a carried-forward set counts toward the completion-window signal and the streak for the resume day, not the day it was generated.
- **Personalization loop**: `user.recent_performance(limit: 10)` returns the last 10 sessions with dates, sections answered, ratings, and concept tags. This is embedded verbatim in the generation prompt so each day's exercises adjust to the user's trajectory. A skipped section's AI grade is not evidence of skill: `recent_performance`'s `ai_ratings`, `ConceptMastery.record_review!` and `User#concepts_needing_reinforcement` read `DailyResponse#answered_concept_tags`, and the prompt labels a skipped section `ai: skipped`. `recent_performance`'s `concepts:` and `User#concept_exposure_index` keep the full set because a skipped section was still shown. `self_ratings` returns the stored map unchanged for historical compatibility; new submissions use the finalization rule under "One finish action."

  **Skipped retention checks defer without changing knowledge.** When a
  submitted, successfully reviewed skipped section tags a vocabulary-valid
  concept whose retention check was due on the response's date, review moves
  its next check one existing interval beyond the user's local review date
  (never before the work date). The interval, tier, streak, last rating and
  mastery timestamp do not change. This releases a fourth slot that the same
  overdue concept could otherwise hold indefinitely. It also postpones a
  genuinely useful check when someone skips it; that is the accepted cost.
  A concept answered anywhere on that response is excluded, even if that
  section's review is still pending. Only successful sections in the current
  batch qualify. The transaction locks the matching mastery rows, and the new
  due date is beyond the work date, so retries and later skipped duplicate
  batches cannot defer the same day's check again.

  No assignment metadata is stored: `DailyPlan` offers concepts and ingest
  stores the provider's actual tags, not which offers it honored. The rule
  therefore applies to a due concept actually shown and reviewed, whether
  explicitly requested as retention or incidentally repeated. It cannot
  infer an unhonored offer and never reschedules unrepresented concepts.
  No backfill repairs mastery changed by historical skips.
- **One "answered" authority**: `DailyResponse.answered?` delegates completion
  to the section kind. Prose still needs more than 10 characters after
  untouched scaffold labels are removed; `ANSWER_MIN_LENGTH` is unchanged.
  Parsons instead needs an explicitly saved complete permutation of its
  stored blocks, regardless of encoded length. One- and two-block exercises
  are supported; the generation prompt's five-to-eight target is not an
  ingest bound. An untouched control stays unanswered. Moving a block records
  the arrangement. A one-block exercise has nothing to move, so only it shows a
  "Use this order" button; with two or more blocks the scramble never starts in
  the correct order and every move already saves. The kind's control supplies
  `data-answer-complete`, initially computed by the server and updated on
  interaction; the shared browser gate reads that state without knowing the
  kind. Prose controls still share the server's threshold and scaffold labels.
  Progress, hint gating, history, mastery and generation all ask the same
  completion authority.

  `DailyResponse#answer_for` delegates review/display representation to the
  kind too. Prose below the floor, including "add index", appears as skipped
  without deleting the stored draft. Parsons preserves malformed attempts
  for its strict local grading and lenient read-only replay, so a corrupt id
  cannot hide the other blocks the engineer arranged; it does not count as
  completed work. Calibration mismatch notes require completion.
- **Answer scaffolds**: `pattern` and `architecture` ask for multi-part reasoning, so the generator returns an `answer_scaffold` — a short list of labels written for that specific question — inside the section's `problem_set` entry. A fresh textarea starts pre-filled with them; they are plain text in the same plain-string answer, so the user can delete or ignore them. Bounded on ingest (`ExerciseSection::MAX_SCAFFOLD_LABELS` / `MAX_SCAFFOLD_LABEL_LENGTH`) since it is provider output rendered into a form, and absent/unusable values fall back to the kind's `DEFAULT_SCAFFOLD`, so pre-scaffold rows render identically. `ResponsesController` normalizes on write: an answer that is nothing but labels stores as `""`, so reloading offers the scaffold again without storing its labels as the user's work. Other draft text remains intact; grading and read-only displays use `answer_for` as described above.
- **One finish action**: each section's difficulty rating autosaves on click, which enables the Submit button — disabled, with a visible nudge, until at least one section is answered and every answered section is rated (`DailyResponse#submit_blocker`, restated by the inline script against the live form). Answers and rating land in one `ResponsesController#create` call, and a successful submit fires the review from that same click — still a separate request, still exactly one review per day, just no second click to reach it. Draft ratings are set-only: `#create` accepts only valid enum values and preserves ratings while answers are edited or cleared. At submission it slices ratings to `answered_sections`, so a cleared, too-short, or scaffold-only answer leaves no self-assessment behind. Partial answer payloads merge into the draft before this slice; omitted answers remain unchanged, and explicit empty strings clear them. The form stays inert during submission and the review handoff, keeping its visible answers and ratings at the submitted snapshot; a failed submission restores editing and recomputes the gate. The progress label reports answers only; the nudge and button report readiness. The dashboard requires JavaScript; rating, autosave, progress, and submit are all driven by the inline script, and there is no server-side rejection of an unsubmittable submit because the UI cannot produce one.
  A refused or dropped submission restarts the draft autosave it canceled, so
  the last edit survives without another keystroke. If submission succeeds but
  the browser cannot start the review POST, the page explains that the answers
  were saved and reloads the submitted state with its manual review button.
  It never restores an editable draft after an acknowledged submission.

  **Partial submission still incurs a full-day review.** The existing review
  fan-out grades every active section, including skipped ones, and also calls
  the difficulty assessment. Skipping a section does not remove its grading
  call or the assessment. Skipped grades stay outside skill evidence; review
  scheduling and provider fan-out are unchanged.

  A submitted self-rating now describes a counted answer. This deliberately
  replaces the earlier policy that retained intentional ratings on skipped
  sections: the final record cannot distinguish those from ratings left behind
  by clearing an answer. Historical submitted rows are not rewritten.
- **Folding a section**: on the answer form each section is its own open
  `<details>`, the disclosure the reference, hint and history already use,
  so a section can be folded away by hand. Nothing folds on its own, and
  folding is available whatever the section's state. The summary carries
  the label, as an `<h2>` so VoiceOver's heading rotor reaches each section
  (never give the summary `role="button"`, which would erase it), and a
  status line (`SectionStatusHelper#section_status`, mirrored
  by the dashboard script's `refreshStatus`): a check and the self-rating
  once answered and rated, "in progress" once answered, blank otherwise. One
  automatic reopen: editing the answer of a folded, rated section opens it,
  since a fold claims the section is settled and a stale rating must never
  sit beside changed text. Native `<details>` hides without unmounting, and
  nothing inside a section needs to be visible to work — the diagram
  renders to an SVG string once at load, the duck and pseudocode controls
  fetch on click, and every autosave listener is on `input` — so the fold
  is purely visual and the submit gate, rating and autosave are untouched.
  Fold state is not persisted: a reload opens every section, which costs one
  tap per section and avoids keying browser storage to a response that
  regenerate and start-over would have to invalidate. The read-only render
  stays a plain div.
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
- **Post-hoc difficulty rating**: once a section is reviewed, its review block
  also shows how hard the PROBLEM was — `straightforward` / `moderate` /
  `demanding` (`DailyResponse::DIFFICULTY_LEVELS`) plus a one-sentence reason —
  so a rough grade can read as "this was legitimately hard" rather than as
  unexplained struggle. Three levels in problem-describing words, deliberately
  disjoint from the 4-level AI grade badge it renders under (a spec holds the
  vocabularies disjoint), because two same-shaped ratings side by side would be
  read as one axis. **It must never become a second readout of
  `ConceptMastery`'s tier**, which the mastery design keeps invisible precisely
  so it cannot shape engagement — so it is assessed at review time by
  `AiService#assess_difficulty`, which is handed *no* `daily_response` and none
  of the user's history. The signature is the guarantee: it cannot see the
  answers, the self-ratings, the grade it runs beside, or the tier, because
  none of them are passed to it. Generation-time was rejected for exactly this
  reason — the generator has just been told "for any concept marked
  `(reduced)` … ease the difficulty only", so a self-assessment there grades
  the instruction it was given; folding it into the grading call was rejected
  because that call's shared context carries every answer and self-rating, and
  a rating drawn from those launders performance (and so, indirectly, tier)
  into "difficulty". Its per-section material comes from
  `AiService#duck_section_context`, already the single authority for "the
  section as the engineer sees it", so it inherits that method's answer-key
  exclusion rather than restating it. Cost is one extra provider call per
  review *attempt* (not per section), billed as `assess_difficulty` and capped
  by `AiService::DIFFICULTY_ASSESSMENT_MAX_TOKENS` — which is sized from the
  largest valid reply plus an allowance for the model overrunning the
  requested length, and, by being passed at all, is what turns off the
  extended thinking `ClaudeService` would otherwise leave on. It runs as one
  more thread in the existing fan-out, and once grading finishes it gets only
  `DIFFICULTY_ASSESSMENT_GRACE_SECONDS` to land before the review goes out
  without it — so the note can add at most that grace period to a request,
  never the provider's whole retry budget; a thread abandoned that way still
  records its `ApiUsage` row, which is honest accounting for a call the
  provider already billed. Any failure in it is swallowed — `StandardError`
  wide, not just `AiService::Error`, because `Thread#value` re-raises past
  `ResponsesController#review`'s rescues, and a note must never cost the
  engineer the review itself. Stored at
  `ai_review[section]["difficulty"]` — no migration, and no pre-answer surface
  can reach it even in principle, since `ai_review` does not exist until a
  *submitted* response is reviewed. Display-only: nothing about tier
  transitions, retention scheduling, or generation guidance changed.
- **Grading rubric**: `AiService::RATING_RUBRIC` is the one definition of
  the four review ratings, stated once in the review's shared day context.
  A rating describes how the answer meets the level its section was pitched
  at, so `solid` means the same at junior and senior: beginner missed the
  main point, developing found it but missed or misexplained an essential
  piece, solid has no essential misses, and strong is solid plus something
  the question did not ask for, such as a tradeoff or a consequence. A gap is
  essential when, left as written, the code or decision would behave wrongly
  or a stated requirement would go unmet. Each kind's grading note names its
  own main point and essential pieces and never restates the levels; a spec
  holds every grader-rated kind to that. Parsons is the exception: its
  `fixed_rating` hook computes the rating in Ruby from how many blocks are
  out of place and replaces the grader's, except when the stored section has
  no blocks to compute from. The hook is the only statement of that rule;
  shared grading code calls it for every kind.

  **The grader is told the pitched level.** `build_review_section_prompt`
  states the section's `pitched_at` rung and its
  `KindDifficulty::LEVEL_DEFINITIONS` sentence, falling back to
  `KindDifficulty#rung_for` (target included) for an unstamped section.
  `eased` is never passed; the rubric instead says a problem simpler than
  its level's description is graded on what it actually asks. The day context no
  longer calls the engineer "junior/mid", which would contradict a senior
  pitch.

  **The rubric is checked, never enforced.** The grader also returns
  `essential_gaps`, the positions in "missed" it counts as essential.
  `RubricCheck` reads them against the rating (solid and strong list none,
  beginner and developing at least one) and `[rubric_check]` logs counts and
  `agrees=true|false|unknown` for every section whose rating the grader
  chose, never review text; a computed rating is not checked.
  Positions it cannot read are dropped rather than stored, and are counted
  against "missed" as the grader returned it, blanks included. Nothing
  rewrites a rating from this; the log is how the rubric's adherence is
  measured. The check runs before the prose judge, and when the judge
  rewrites a review the positions move into `graded_prose`, beside the list
  they number.

  **`AiService::RUBRIC_VERSION`** is stamped into every review the prompt
  grades (`ai_review[section]["rubric"]`, server-owned). A review without it
  was graded with no rubric, so its rating answers a different question; an
  evidence reader that compares ratings to a bar reads only stamped reviews.
  A stamp rather than a cutoff date, because grading knows which prompt it
  ran and a date misfiles a review retried across a deploy. Only the
  competency gate reads it; `ConceptMastery`, `RungLedger` and
  `TrackGraduation` read all history on purpose. Going forward, a concept's
  first post-rubric review is compared with a pre-rubric `last_rating`, so
  that one comparison can read as improving or stagnant because the scale
  moved rather than the engineer.

  **Calibration.** `script/compare_models.rb review_calibration` grades the
  complete, partial and missed answers in `spec/fixtures/review_calibration/`
  through the production review route and reports whether each fixture's
  three ratings fall in rank order, how many complete answers reach solid,
  and the run's cost including cache writes. At introduction it ran 5/5 in
  order and 15/15 at the expected rating on Claude, about $0.21. The fixtures are deliberately
  clear-cut: they show the levels separate, not where a borderline answer
  lands. The design comparison fixture, added later, also carries two extra
  answers with their own expected ratings and has not been run yet.
- **Review prose judge**: an optional second pass over each graded review,
  for readability only. `AiService#judge_review_prose` reads the review as the
  page renders it (`ReviewProseVerdict.project`) and may reword its prose
  fields for plain language or length; it is never shown the answer, the
  problem or the grading note, so it has nothing to regrade from. The
  signature is the guarantee, as with `#assess_difficulty`. Verdicts are
  `keep` or `edit`, with issue types `plain_language_violation` and
  `verbosity`.

  **What is mechanical.** `ReviewProseVerdict.parse` is the boundary. It
  refuses a status or issue type outside the closed lists, a rewrite of any
  field that is not one of `DailyResponse::AI_REVIEW_FIELDS`, a blank rewrite,
  and a list field that does not cite every original entry exactly once, in
  order, at its earliest source's position; a merge of entries needs a
  `verbosity` issue. A rewrite of a field that was empty is dropped rather
  than refused: it has nothing to cite, so it can only be invented, and
  refusing would also discard a sound rewrite of another field. An edit left
  with nothing after that reads as `keep`. Grade, rating and every other
  field are protected because only the prose fields can be named. On a `keep` or a fallback the
  grade is stored as the provider returned it, and `grade_section` strips any
  `graded_prose` key the provider sent, since `graded_prose` is server-owned:
  an edit stores the grader's original prose there, exactly as returned, as
  the audit record.

  **The accepted risk is claim preservation.** Citation proves no point was
  dropped or duplicated; it cannot prove a rewrite still says the same thing.
  A negation, a condition or an identifier could change and nothing checks it.
  That is why the judge ships off.

  **Placement and failure.** `AiService#judged_review` runs inside each
  section's grading thread, after grading and the Parsons rating override, and
  has its own rescue. It rescues `StandardError`, not just `AiService::Error`,
  because `Thread#value` re-raises whatever `grade_section`'s narrower rescue
  misses, and no judge failure may cost the engineer the review. A failure
  returns the grade unchanged and logs `[review_judge_fallback]` with a fixed
  reason code from `AiService.judge_fallback_reason`, the table the section
  judge also reads, never the error message, which can carry provider text. The call is billed as `judge_review`, which is in
  `ApiUsage::PURPOSES`, and capped by `REVIEW_JUDGE_MAX_TOKENS` (1,500). That
  cap came from a local sample of only four reviews, so it must be re-checked
  against the output tokens the comparison script measures before the switch
  goes on.

  **One attempt, and a 12-minute claim.** The call passes `single_attempt:
  true`, which refuses every retry, status retries included, and runs on
  `REVIEW_JUDGE_READ_TIMEOUT`. The grading stage's time budget now includes
  that one call (`OPEN_TIMEOUT + REVIEW_JUDGE_READ_TIMEOUT`), so
  `DailyResponse::REVIEW_CLAIM_STALE_AFTER` is 12 minutes, whether or not the
  switch is on. A claim window shorter than the chain would let a second
  review start while the first is still running.

  **Claude only.** `AiService.judges_review_prose?` is false on the base class
  and true on `ClaudeService` (and `FakeService`, for specs), because the
  judge relies on structured output, which `GeminiService` does not send yet
  (#228). A Gemini user is never judged. Neither is an OpenAI user: its JSON
  mode does not hold the reply to the schema, and the comparison script that
  gates the switch runs only Claude models.

  **Logging.** The `[review_judge]` line records status, issue types, merge
  indexes and timing, never review text, and the reply is parsed with
  `log_raw: false`. Transport-level raw-response logging in the provider
  subclass may still record the text; that path is not the judge's.

  **The switch and the activation gate.** `ReviewProseJudge.enabled?` is true
  only when `REVIEW_PROSE_JUDGE` is exactly `"1"`. It ships off. Before
  turning it on: run both `review_prose` modes of `script/compare_models.rb`
  (`review_prose` on stored days and `review_prose_fixtures`), read every
  rewrite beside its sources, and confirm no claim changed, including
  negations, conditions and identifiers. Check the measured output tokens
  against `REVIEW_JUDGE_MAX_TOKENS` at the same time, and the slowest
  measured calls against `REVIEW_JUDGE_READ_TIMEOUT` (30 seconds): the call
  has one attempt, so a timeout is billed and then falls back.
- **One reviewed-response invariant**: once `DailyResponse#reviewed?` is true,
  `ConceptMastery.record_review!` has already moved tier, streak and retention
  state off that review, and nothing can undo it. So no action destroys a
  reviewed response: `ResponsesController#start_over` and
  `DailyExercisesController#regenerate` both refuse, and `RegenerateExerciseJob`
  re-asks under the row lock `#review` takes, because the controller's answer is
  a worker hop and a provider call old by the time the destroy runs — abandoning
  the whole regeneration (claim released, the day's one regeneration preserved)
  rather than replacing a problem_set the standing review describes. A review
  merely in flight (`DailyResponse#reviewing?`, the same stale-claim window
  `#review` claims with) blocks the same way; an abandoned claim past that window
  does not.

  **Accepted consequence of chaining review onto submit:** the reconsider window
  that used to sit between the two clicks is gone. Both guards fire within
  milliseconds of a submit now — `reviewing?` for the length of the provider
  call, `reviewed?` for good after it. The success path does land back on the
  dashboard's submitted state, where "Start over" and "Generate new set" live,
  but both render only while `reviewed?` is false, so neither is there once the
  review it would discard exists. Reconsidering belongs before submitting,
  which is untouched. Afterwards those two are reachable only when the
  automatic review failed outright, or once an interrupted claim goes stale
  with no section written. A partial review blocks them exactly as a partial
  manual review always did.

- **The Learn tab**: `/learn` lists every concept in the user's vocabularies —
  their language plus the four language-independent buckets, both languages
  for a `"mixed"` user — not only ones they've been assigned. It reads
  `user.language`, never `#language_for_today`: that method resolves "mixed"
  to one concrete language for a single day's generation, and a library's
  contents must not change depending on which language tomorrow happens to
  be. **This deliberately shows the full explanation before first exposure** —
  the opposite of `ConceptReference`'s first-exposure-only auto-expand
  everywhere else, which exists because reading an explanation before
  attempting a problem replaces effortful retrieval with recognition. A
  locked, title-only teaser was offered and declined. This trade is scoped to
  this tab; it is not a precedent for loosening exposure gating on the inline
  dropdown, the duck's explain mode, or anywhere else that logic runs.
  The guide (`AiService::CONCEPT_GUIDE_FIELDS`) is produced by the *same*
  `#generate_concept_reference` call that writes the inline reference, in one
  request — so the two cannot drift apart by construction rather than by
  hope. `CONCEPT_REFERENCE_FIELDS` is deliberately not extended (it is read by
  `#explain_concept_differently` to build "the reference they've already
  read," and widening it would silently change that prompt), and the guide
  fields are deliberately outside the required-field check
  `#generate_concept_reference` already runs — so a provider that flubs the
  guide still leaves a usable inline reference rather than failing a call that
  used to succeed. `guide_worked_example` asks for a contrastive PAIR of the
  same scenario — same names, same shape, so the difference reads structurally
  — and for the mechanism relating them stated outright ("X causes Y") rather
  than an association. Which *kind* of contrast is a property of the concept,
  not of the vocabulary it arrived in: `AiService::TRADEOFF_CONCEPTS` gets
  option A against option B with neither called corrected, everything else gets
  failure mode against fix. That constant is **written out rather than derived**
  from `ARCHITECTURE_CONCEPTS`: a derivation would hand the tradeoff framing to
  every architecture concept added later without anyone deciding it has two
  sides, and a reference is cached forever, so a concept framed wrong stays
  wrong. A spec holds every architecture concept to a deliberate
  classification, so growing that vocabulary fails until someone chooses a side
  for the new one. The list is mixed-vocabulary because the shape follows the
  concept: `COMPLEXITY_CAUSE_CONCEPTS` sit inside `ARCHITECTURE_CONCEPTS` and
  are things to catch, so they are absent, while `denormalization_tradeoffs`
  arrives from both language vocabularies and is a real decision. The test is
  whether the concept has two defensible sides (at-most-once against
  at-least-once), never which group it sits nearest, and deliberately not the
  `ANTI_SHAPE_CONCEPTS` axis, which answers a different question. That concept being planted as a flaw on a
  schema-review day and taught as a tradeoff here is not a contradiction:
  grading one instance and explaining the concept are different jobs. The
  inline `code_example` is untouched — it stays terse and single-snippet,
  because it serves first exposure. This is the one guide field past the
  two-paragraph cap, and it carries a stated bound of its own
  (`WORKED_EXAMPLE_BOUND`) rather than none, since an unbounded field drifts
  into the essay the guide exists not to be. Three triggers, not one: a
  user-initiated backfill for
  concepts with no row at all, on-demand regeneration — only when someone
  opens that concept's Learn entry — for a legacy row that has a reference but
  no guide, and `POST /learn/prepare_ladders`, which rewrites the ungrounded
  concepts behind a user's difficulty targets (see "Difficulty targets and
  locks" below). Bulk-rewriting legacy rows would change inline reference
  wording nobody asked to change; confining the first two to on-demand accepts
  that **an inline reference's wording can change once, for a concept someone
  deliberately opens.** `prepare_ladders` is the one scoped exception to that
  rule: it rewrites rows on demand, but only for concepts behind a target the
  user set, from a click whose own copy says the wording may change.
  `ConceptReference` has no `user_id` — it's a shared, team-wide cache
  keyed on `(concept, language)`, so the first person to run the backfill pays
  for everyone and every later teammate pays almost nothing. Roughly $0.02 per
  concept, an estimate from before the reference moved to `claude-sonnet-5-5`
  at effort `high` (the new effort level changed the cost by an amount nobody
  has measured), so a couple of dollars for one user's
  whole slice, growing with it — no count is quoted here on purpose, since the
  last one went stale the first time a vocabulary grew. The rate is an estimate
  from prompt shape rather than a measurement, and both it and the slice's size
  are checkable against `ApiUsage` rows under
  `purpose: "generate_concept_reference"`. The "seen in your sets" marker
  derives from `User#concept_exposure_count` (submitted responses only), never
  from `ConceptMastery`: tier is kept invisible everywhere by design, and a
  marker sourced from it would be exactly the readout the post-hoc difficulty
  rating went to lengths to avoid becoming.
- **Recognition guides**: each recognition group on the Learn index carries
  one generated piece on how to look for that kind of problem
  (`RecognitionGuide`, table `recognition_guides`), in a disclosure at the top
  of the group's block, above its concept list. A recognition group is a named
  `ConceptGroup` or a language-independent bucket, whose flat list already is
  one group; a language bucket's `core` group has no shared identity and gets
  none. The guide teaches a process, never an answer: it never defines one
  concept, which is `ConceptReference`'s job, and never hints at a planted
  defect. `AiService::RECOGNITION_GUIDE_SCOPE` states that in the prompt, and
  `#generate_recognition_guide(user, group_key)`'s signature holds it, since
  it is handed no exercise, response or history. It is therefore shown with no
  exposure gating. One row per group, shared across languages and the team,
  written by `GenerateRecognitionGuideJob` from the existing "Write up the
  rest" backfill and never rewritten; all three fields are required, so a
  flubbed response writes nothing and the next backfill retries. Two framings
  are derived rather than branched: a group holding any `TRADEOFF_CONCEPTS`
  gets a line saying those are choices, and meta skill is framed as the habit
  its tracked concepts exercise together (`RecognitionGuide::FRAMINGS`),
  since its concepts are already process concepts. Nothing else reads a
  guide. Design:
  `docs/superpowers/specs/2026-09-29-recognition-guides-design.md`.
- **Book citations**: `ConceptBookSources` maps a concept to an ARRAY of
  reading pointers — title, author, and where the book has one, the term the
  book itself coined — rendered as "Where this comes from" at the bottom of a
  `LearnController#show` page and nowhere else. Static and hand-curated, like
  `Glossary`: **it is never sent to a provider, and that is the whole design.**
  A generated citation is a hallucinated one, and a `ConceptReference` row is
  cached forever, so the guarantee has to be that no prompt can reach the data
  rather than that a prompt is asked to behave — a spec pins that no source
  title appears in the concept-reference prompt. `CONCEPT_REFERENCE_FIELDS` and
  `CONCEPT_GUIDE_FIELDS` are deliberately untouched by it, since widening
  either would silently change `#explain_concept_differently`'s prompt and the
  required-field check. Array-valued from the first commit rather than promoted
  later: `shotgun_surgery` carries two sources on day one. A citation is
  additive metadata — adding one never changes a concept's definition or its
  grading criteria. The rule nothing mechanical can enforce: a pointer names a
  term the book coined, never a chapter or page number, because a number
  recalled rather than checked is a fabrication that reads as authoritative.
  Audit behind the current entries:
  `docs/superpowers/specs/2026-09-12-four-book-concept-audit.md`.
- **The daily featured concept**: one concept surfaced each day, the same one
  for the whole team — `ConceptReference.featured`, read at the top of `/learn`
  and as a small callout on the dashboard. **Global, not per-user**, because
  `ConceptReference` is itself a shared row with no `user_id`; no per-user state
  exists for this and none should be added.

  **Picked lazily on visit, not by a cron entry.** The first page load of a day
  that asks finds no row stamped with that date, takes the stalest one and
  stamps it; every load after reads it. The date being asked about is the
  method's only input, so a Saturday behaves exactly like a Tuesday with
  nothing to configure — unlike generation, which `config/recurring.yml` and
  `GenerateDailyExercisesJob` deliberately gate to 8am weekdays. Ordering is
  `featured_on ASC NULLS FIRST`: a never-featured concept outranks every dated
  one, the same "unseen outranks stale" rule `SectionRotation` applies to
  exercise kinds.

  **Selects and displays only — it never generates.** Every field it renders
  was written by the Learn tab's existing `#generate_concept_reference`, so the
  feature adds no provider call and no `ApiUsage` row (a spec pins that). A
  featured row whose guide was never written needs no fallback of its own: the
  callout links to the ordinary `LearnController#show` page, which already
  offers the on-demand "Write this up" control for exactly that row.

  **The pool is the four language-independent buckets**
  (`ConceptReference::FEATURABLE_BUCKETS`, derived from
  `ConceptBucket::LANGUAGE_INDEPENDENT`), not every vocabulary. A single global
  pick has to be readable and relevant to everyone, and `LearnController#show`
  validates `:bucket` against the viewer's own slice — so a `javascript` pick
  is a 404 for a Rails user, and the reverse for a JS user. On a team split
  across stacks these are the only concepts that are genuinely
  one-for-everyone. Accepted cost: neither language vocabulary is ever
  featured, and they are the larger half. No count is quoted here on purpose —
  the rotation's length is however many rows the pool holds, and growing a
  vocabulary only lengthens it; two specs hold the exclusion itself, which is
  the part that can break.

  **The day is the team's, never the viewer's.** `ApplicationController`'s
  `around_action :use_time_zone` runs every action inside the current user's
  zone, so a bare `Date.current` in `.featured` would resolve per viewer — two
  teammates either side of midnight would ask about different dates, each stamp
  a row, and each get their own "today's concept", which is the one global pick
  this feature exists to be, broken. The unique index cannot catch that, since
  the two dates genuinely differ. `ConceptReference.team_today` resolves it in
  `User::DEFAULT_TIME_ZONE` — the zone `User` already falls back to and
  `config/recurring.yml` already calls the team default — rather than a second
  constant of the same value that could later disagree. UTC was the alternative
  and is worse: it rolls the concept over mid-evening for this team.

  **The same-day race guard is the unique index on `featured_on`**, not a row
  lock. Two first-visits landing together both read nothing and both try to
  stamp; the loser's write violates the index, and `.claim_feature` rescues
  `RecordNotUnique` by re-reading the winner's pick, so both visitors see one
  concept. Deliberately lighter than the `with_lock` the cost-bearing paths
  take (`User#resume_generation!`, `ResponsesController#review`) — this picks a
  row to *read*, so losing costs a re-read rather than a duplicated provider
  call. The stamp sits in a SAVEPOINT (`requires_new: true`) for the same
  reason `PushSubscription.upsert` and `User#carry_forward` do: without one the
  write joins a caller's open transaction and the violation aborts it, so the
  recovery read raises `PG::InFailedSqlTransaction` instead of returning the
  winner. No caller opens a transaction around it today — and note that
  transactional specs cannot surface this, since Rails opens its test wrapper
  non-joinable and `update!` then gets a savepoint of its own; the spec that
  pins it opens an ordinary caller transaction explicitly.
- **Idempotent saves and frozen evidence**: `ResponsesController#create`
  shares `persisted_response_for` with pseudocode rounds, recovering an
  initial-create race through the existing unique date constraint. Every
  answer save reloads under the response row lock. Once submitted, answers,
  section ratings, concept tags and the submission timestamp are immutable
  through this endpoint, including while a review is running or retrying.
  Ratings freeze too because they decide mastery alongside the AI grade.
  Draft answer merging and submit-only rating pruning both run inside that
  lock, before the first submission freezes the record.
  Stale autosaves receive a successful acknowledgement with `submitted: true`,
  without changing evidence, and the stale form reloads to the submitted
  page. Repeated submits return the existing review URL, preserving automatic
  review retries. The form's inert state suppresses that reload during submit,
  so a late autosave cannot interrupt its review request. Start over and
  regeneration retain their existing reviewed/reviewing guards.
- **Preview apps**: a Railway PR environment starts with an empty database and
  needs no configuration. `railway.toml`'s `[environments.pr.deploy]` block
  exports `PREVIEW_APP=1` into both the pre-deploy and server processes, and
  `PreviewEnvironment.active?` is the single authority every preview behavior
  derives from: `PreviewSeed` (three days of demo content for one account),
  `PreviewMail` (inline delivery, so login never waits on a worker), and
  `PreviewAutoLogin` (an unauthenticated request is signed in as the seeded
  user — and only as an account `PreviewSeed.seeded?` recognizes as its own,
  so a real account sitting at that address, which the seeder deliberately
  leaves untouched, is never signed into). `PREVIEW_SEED_EMAIL` is now only an
  optional override of *which*
  account — `PreviewSeed::DEFAULT_EMAIL` covers the normal case — so setting it
  at the wrong Railway scope no longer does anything on its own. Nothing in the
  repo turns auto-login on outside a PR deployment: `pr` is a hardcoded key
  Railway resolves itself, production's
  deploy config comes from `[deploy]` which exports nothing, and the app's own
  config never sets `PREVIEW_APP`, so `PreviewAutoLogin`
  registers its callback — gated on the same `PreviewEnvironment.active?` — only
  there; in production the callback is not in the chain at all. `PREVIEW_APP`
  is still an ordinary environment variable, though: typing it into a
  production or shared-scope Railway variable would enable this, which is why
  the name is reserved for PR deployments and set from committed config only.
  It skips
  `SessionsController`, so real code login is unchanged and still
  testable, and a deliberate logout sets a cookie that keeps the reviewer
  signed out.

  **Accepted tradeoff:** a PR app's URL is internet-reachable, so this replaces
  "public URL, login wall" with "public URL, no wall" for anyone holding the
  link. The seeded account carries `PreviewSeed::DUMMY_API_KEY` and fabricated
  history in a throwaway database, so the blast radius is bounded — but the
  change is deliberate, not an oversight.

  **`DEFAULT_EMAIL` is undeliverable on purpose** (`.invalid`, RFC 2606), so it
  can never collide with a real mailbox. The cost is that a preview app's
  mail-sending actions (the "Email me this review" button, a login code
  requested for that address) fail loudly rather than silently: `PreviewMail`
  delivers inline and production config sets `raise_delivery_errors`. Set
  `PREVIEW_SEED_EMAIL` to a real address on the PR environment when a reviewer
  needs those paths to work.
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
- **Parsons input**: drag (SortableJS, CDN) is the primary reorder mechanism;
  up/down arrow buttons are injected by script only if that import fails or
  stalls for 3s. Because dragging is pointer-only, every block is focusable and
  reorderable with Ctrl+↑/↓ (bare ↑/↓ moves focus), with an `aria-live` status
  line announcing each move — that keyboard path, not the arrows, is what keeps
  the section answerable without a mouse.
- **Home-screen app**: `GET /manifest.json` (Rails' own `PwaController`, so it
  needs no session) plus the `apple-mobile-web-app-*` meta tags in the layout
  make an iOS home-screen launch open standalone instead of inside Safari's
  chrome. The `apple-` meta tags are not redundant with the manifest — iOS reads
  `display: standalone` only from 17.4. `status-bar-style` is `black`, so
  content stays below the status bar and nothing needs `viewport-fit=cover` or
  safe-area insets. `app/assets/images/logo-outlined-square.png` is the source
  of every icon; `script/generate_icons.py` rasterizes `favicon.ico` (32px
  only, since the art turns to mush at 16px), `icon-192.png`, `icon-512.png`,
  `icon-maskable-512.png` and `apple-touch-icon.png` from it, nearest-neighbor,
  onto the layout's `--bg`. `logo.png` and `logo-square.png` are the same art
  without the light outline, unused while every surface the logo sits on is
  dark.
  Standalone mode itself still needs no service worker — but one is registered
  now, for the daily reminder (see "Push reminders" below); `GET
  /service-worker.js` serves it from the root path, since a worker's scope is
  the directory it is served from.

  **Pull-to-refresh in the installed app.** The layout's
  `overscroll-behavior-y: none` removes the rubber-band bounce, and with it
  the only way to reload a home-screen launch, which has no reload button.
  `shared/_pull_to_refresh` adds the gesture back as plain touch listeners on
  top of that rule, which is unchanged. It follows the iOS pattern: the nav
  stays where it is while the layout's `[data-pull-content]` slides down with
  UIScrollView's rubber-band resistance, and the spinner, layered beneath both,
  shows in the gap that opens. The content's transform is cleared whenever it
  comes to rest, since a transformed ancestor would re-anchor any
  `position: fixed` element inside the page. It reads standalone mode from whether
  its indicator is displayed, and only the layout's `display-mode: standalone`
  block displays it, so that media query stays the one standalone test and a
  browser tab keeps its native pull. The action is a full reload, and it
  waits for `CodeGymSaveStatus.pending()` to clear first: that counts
  requests on the wire plus the delayed saves the dashboard and /setup
  register through `watch()`, since both hold an edit for a moment before
  sending it. Their scripts are inline in the page body, which runs before the
  layout defines `CodeGymSaveStatus`, so they register on `DOMContentLoaded`.
  A save still pending after ten seconds cancels the pull rather than
  reloading over it. The gesture also refuses to start while a text field has
  focus, while any form is `inert` (the dashboard's submission and review
  handoff), or inside an inner area scrolled away from its top. On release the
  content settles to a held gap and the spinner turns for at least half a
  second, and a sessionStorage note lets the reloaded page open still held
  with the spinner turning, and settle once loaded, since the page it was drawn on is gone by then. Playwright cannot emulate
  `display-mode`, so `spec/requests/pwa_spec.rb` pins the stylesheet rule and
  `spec/system/pull_to_refresh_spec.rb` forces that rule on to drive the
  gesture.
- **Display preferences**: theme (dark, light, match my device), background
  pattern (on/off), text size (100/112/125/140%), line spacing and a reading
  font (Atkinson Hyperlegible;
  OpenDyslexic is deferred to #235, pending its license's rule on renamed and
  converted copies). They live in a Display disclosure on Setup and save
  through `PATCH /profile`. `DisplayPreferences` is the one list of choices,
  defaults first. `users.display_preferences` is sparse jsonb, since a default
  stores no key, and `User` plus `ProfileController` refuse anything outside
  the lists. Saves are chained one at a time because each carries the whole
  object.

  **The background pattern is deliberately on by default**, an exception to
  display changes requiring an opt-in. Two white, alpha-channel tiles mask a
  fixed layer at a 288px repeat size: `gym-pattern-tile.png` emphasizes
  outlines on light, and `gym-pattern-tile-dark.png` emphasizes fills on dark.
  The layout sets `--pattern-mask`, tint and opacity for dark; the existing
  light stylesheet overrides all three, so its media rule also selects the
  artwork for "Match my device" without another theme switch. Light uses
  the logo's shirt blue, `rgb(52, 97, 154)`, at 7%; dark uses
  `rgb(190, 205, 240)` at 8%. The layer sits outside `[data-pull-content]` and
  below the refresh indicator, so neither scrolling nor the pull gesture
  moves it. Off omits the layer from the response; Setup adds or removes it
  immediately. High contrast and forced colors hide it, as does missing
  mask support. Both standard and `-webkit-` mask declarations are present.
  No migration: only an explicit `"background_pattern": "off"` is stored
  in the existing sparse jsonb. `palette_contrast_spec` checks a fully
  opaque mask pixel, including through tinted backgrounds.

  **The other display defaults remain unchanged**: no attribute on
  `<html>`, no stylesheet link, the same outlined logo, the same `black`
  status bar. A chosen value renders as a `data-*` attribute on `<html>` for
  the first paint. `display.css` holds text size, spacing and the font;
  `display_light.css` holds the light palette. The layout links both only for
  a user with a stored choice, on Setup, and on signed-out pages, which follow
  the device. The light palette is unscoped, and its `<link>`'s `media`
  (`DisplayPreferences#light_palette_media`) decides where it applies; the
  logo's `<source>` and a light `theme-color` tag carry the same value, so none
  of the three can disagree. The dark `theme-color` follows as the fallback.

  **The nav's collapse is a container query**, `@container (max-width:
  37.5em)` on `nav`: 600px at the default size, and it moves out as the text
  grows. It stays one rule rather than a copy per text size. Containment makes
  `nav` a stacking context, hence its `z-index`. The reading font and line
  spacing apply to prose only (`p`, `li`, `dd` and the named prose
  containers), never code. iOS reads the status bar style when the installed
  app launches, so only an explicit Light asks for the white bar, and the copy
  says to fully close and reopen the app. Mermaid already draws with its light
  theme, so the light palette needs nothing for it. `palette_contrast_spec`
  holds both palettes to WCAG AA. Design:
  `docs/superpowers/specs/2026-09-30-display-preferences-design.md`.
- **Push reminders**: an optional notification each weekday when the day's set
  is ready, and an optional afternoon nudge on days it is left unfinished,
  turned on and off on the Account page.
  The nudge window is `PushNudgePlan::NUDGE_HOURS` (13-17 local, inclusive), so
  an unfinished day sends at most five on the hourly cron — a bound that belongs
  to the schedule, not to the plan object, which holds no dedupe.

  **Submission is the whole stopping rule, and starting is not.** An untouched
  day, a half-answered one, and one answered in full but never submitted all
  qualify — a set someone got two sections into and walked away from is exactly
  what a reminder exists to reach, so going silent the moment anything was
  typed left the commonest abandonment unreachable. `SendPushReminderJob` picks
  the copy from how far through the day is
  (`SendPushReminderJob::NUDGE_TITLES`), since "still waiting" reads as not
  having noticed the half that was done. A partly answered day whose answered
  sections are rated gets the ready-to-submit nudge, explicitly naming the
  remaining sections as optional. A partly answered, unrated day still gets
  the partway nudge; a fully answered, unrated day asks for ratings.
  `DailyResponse#submit_blocker` is the one authority for that gate, read by
  the dashboard's submit button and, through `#submittable?`, by the nudge,
  so a notification can never name a button the user cannot press. Readiness
  does not stop nudges: submission and `PushNudgePlan`'s quiet period still do.

  **`PushNudgePlan::QUIET_PERIOD` is what keeps that from nagging.** With
  starting no longer silencing the day, an hourly tick would otherwise tell
  someone mid-answer that they have sections left. A nudge holds off until the
  day's `DailyResponse` has been untouched for an hour — its `updated_at`,
  which moves only when a save actually changes something, so an idempotent
  autosave of unchanged answers doesn't reset it. One hour is what covers a
  whole tick of the production schedule, so a save silences the next nudge
  whatever minute it landed on; a shorter period would let a save early in the
  gap between two ticks be past it by the time the later one ran.
  `push_nudge_plan_spec` reads `config/recurring.yml` and fails if that
  schedule shortens, rather than leaving the justification to a comment.
  Development's five-minute schedule is deliberately not pinned, since a quiet
  period spanning several of its ticks breaks nothing.
  It delays rather than silences — an abandoned day still qualifies on
  every later tick of the window, which is where the five-per-day bound above
  still comes from. A day with no response row at all has no activity to be
  quiet since, so it nudges from the window's first tick exactly as before.
  `WebPushCredentials` is the
  single authority for "is push configured here at all" — with no VAPID pair in
  ENV the control doesn't render, the layout emits no script, `POST
  /push_subscription` 404s and `SendPushReminderJob` returns without contacting
  a push service, so an unconfigured deployment offers nothing that could only
  fail. Setup and key generation: `docs/deploy/web-push-setup.md`.

  **The endpoint is held to a host allowlist at the boundary.**
  `PushSubscriptionsController::ALLOWED_ENDPOINT_HOSTS` matches by domain
  suffix, because an endpoint is minted by the browser's own push service and
  can only come from a known handful of hosts. Without it the stored endpoint
  is an arbitrary URL chosen by whoever is logged in, which the worker then
  POSTs to on every reminder from inside the deployment's network — a blind,
  authenticated SSRF primitive. A refused host is logged with its name, so a
  browser using a service the list doesn't yet name is diagnosable rather than
  a silent failure to enrol.

  **Intent and transport are separate facts, deliberately.**
  `User#reminder_level` is the answer to "how much does this person want to
  hear from us"; `PushSubscription` rows are the endpoints that can
  currently reach them. iOS drops subscriptions on its own, so an endpoint has to be able
  to die without taking the user's answer with it — that is what lets the next
  launch re-register silently instead of asking again for a permission the
  browser already granted. Turning reminders off clears both; anonymizing an
  account clears both, since a home-screen install keeps its browser-side
  subscription after the account is gone.

  **Both reminders are enqueued by `GenerateDailyExercisesJob`'s cron branch,
  not scheduled on their own.** "It is this user's 8am on a weekday" already
  has an owner and a second cron entry would be a second place for it to
  drift — and the tick is already hourly, so a nudge needs no new schedule.
  That branch's `exists?` check is therefore a fork rather than a gate: the
  tick that finds no set generates and sends `:ready`, and later ticks consult
  `PushNudgePlan` and may send `:nudge`. What stops the nudge repeating all
  day is the user finishing the set, not the hour having passed once. The
  on-demand branch still enqueues neither — a user who triggered generation by
  opening the dashboard is already looking at the set.

  **Intent is a three-value dial, `User#reminder_level`** (`none` / `ready` /
  `ready_and_nudges`). `#push_reminders_enabled?` is derived from it rather
  than stored, because that name answers transport as well as intent: the
  layout's re-subscribe script uses it to ask whether this browser is enrolled
  at all, which the dial does not change.

  **The permission call must be the first synchronous statement in the click
  handler.** iOS grants a prompt only to a request made synchronously inside a
  user gesture and fails *silently* otherwise — no prompt, no console error.
  So `accounts/_push_reminders` calls `Notification.requestPermission()` before
  anything else, the VAPID public key is rendered into the page rather than
  fetched, and the service worker is registered inside the resulting `.then()`.
  A request spec pins the key's presence in the page, since that is what
  removes the round trip that would otherwise have to precede the call.
  Capability is tested as `"PushManager" in window` rather than by sniffing
  `display-mode` or an iOS version: on iOS that property is simply absent
  outside a Home Screen app, which is the thing actually worth knowing and
  stays true however a given release reports itself.

  **Accepted limitation, not a defect to perfect away:** web push on iOS is
  materially less reliable than native push. Subscriptions are dropped after
  inactivity or for no visible reason, delivery rates well below native are
  widely reported, and a user's only recovery is often toggling the OS setting
  or re-adding the Home Screen app. Two mitigations are built in — `PushDelivery`
  prunes an endpoint the moment a push service reports it gone (404/410), and
  every page load re-subscribes and re-registers (`shared/_push_script`,
  skipping the write when the endpoint is one the server already holds). The
  second has a hole that cannot be closed from here: it only repairs the
  subscription of someone who still opens the app, and a user who has drifted
  away — exactly who the reminder is for — generates no launch for it to run
  in. Desktop and Android endpoints are stable and none of this applies to them.

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
cp .env.example .env
# fill in DATABASE_URL, SECRET_KEY_BASE, and the ACTIVE_RECORD_ENCRYPTION_* keys
bundle install
rails db:create db:migrate
bin/dev  # starts web + solid_queue worker
```

In development, login code emails open in the browser via `letter_opener` gem (no SMTP needed).

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
Running them locally requires a one-time Playwright CLI install — see the
comment block at the top of `spec/support/system_test_helper.rb` for the
exact commands. The npm manifests live in `spec/playwright/`, not the repo
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

- `app/models/learning_track.rb` — track values and preset levels.
- `app/services/track_graduation.rb` — pure proposal rules: own-result moves, struggling moves and a lead-based bundle.
- `app/services/track_graduation/evidence.rb` — bounded, preloaded reviewed-response history projected into stamped, answered results.
- `app/services/reviewed_section_results.rb` — `ReviewedSectionResults`: which sections of one submitted, reviewed response count as evidence of work at a rung, optionally only under the current rubric. Pure over the response it is given; shared by `TrackGraduation::Evidence` and `CompetencyGate::Evidence`.
- `app/services/competency_gate.rb` — `CompetencyGate`: the pure fold that earns a day's size from reviewed days, with the brake. `DailyPlan.size_for` calls it once per plan.
- `app/services/day_size.rb` — `DaySize`: the day's planned count and its reason, from the Daily sections setting, the completion count and the gate's `Plan`. Pure; its `Decision` also answers whether the brake is on, for the coverage exception, and what the `[set_size]` line logs.
- `app/services/size_forecast.rb` — `SizeForecast`: whether tomorrow's Automatic set will be larger, or smaller because of the brake, than today's planned one, for the submitted dashboard's size lines.
- `app/services/competency_gate/evidence.rb` — the gate's only query: every rubric-stamped reviewed day, oldest first, in batches, as `CompetencyGate::Day` values.
- `app/controllers/welcome_controller.rb` — the first-run experience question; choices save through `ProfileController`.
- `app/controllers/learning_track_dismissals_controller.rb` — records Not now cutoffs for the current user under the user-row lock.
- `app/views/dashboard/_track_proposal.html.erb` — submitted-day proposal, removable bundle and in-place Apply/Not now saves.
- `script/prepare_junior_ladders.rb` (+ `script/junior_ladder_preparation.rb`) — operator coverage report; explicit `--run` queues shared-reference refreshes using the operator's key.
- `spec/requests/existing_account_pages_spec.rb` — exact pre-track Dashboard, Setup, Account and History snapshots. `UPDATE_PAGE_SNAPSHOTS=1` intentionally rewrites fixtures; never use it to conceal a learning-track regression.
- `app/services/ai_service.rb` — provider-agnostic base: prompts, concept vocabularies, JSON parsing, usage logging. Owns the difficulty scale's prompt text and `#assess_difficulty`'s deliberately narrow signature; `DailyResponse.usable_difficulty` owns what a storable/renderable assessment is, and is applied on write and again on read. Also owns the judge prompt, the single-section retry call, and the two-stage entry point: `#generate_judged_exercise` drafts, then hands the draft to `JudgedGeneration`
- `app/services/judged_generation.rb` — `JudgedGeneration`: the two-stage path after the draft. Fans the judge out a section at a time, retries a rejection, or a planned section ingest refused, up to its kind's `judge_retries` times (twice for a fixed kind, once otherwise) with its concept fixed, drops a rejected last retry, re-judges a design comparison's edits, and hands the final set to `AiService`'s shared logging tail. It reaches the provider only through `JudgedGeneration::Provider` (`judge_section` and `retry_section`, as callables built fresh per call), so its specs need no provider subclass. `JudgedGeneration::UnhostedConcepts` names the planned concepts a drop left without a host
- `app/services/problem_set_ingest.rb` — the generation boundary: holds concepts to their closed vocabulary, bounds scaffolds and diagrams, rolls the parsons scramble, runs each resolved section's own `.reject_unusable!` check, leaving a refused section out and reporting it on `Result#unusable_sections`, and logs a section the day never asked for. Writes nothing to the database — off-vocabulary concepts come back on the `Result` for `AiService` to record, so a rejected set structurally cannot leave a `SuggestedConcept` row behind, and its specs need no database. Not side-effect free, though: `warn_unrequested_sections!` logs.
- `app/services/daily_plan.rb` — the day's plan (third section, reinforcement, the shared concept, retention checks and the ones left waiting, the coverage addition, `code_review` mode and the real-source excerpt grounding it, if any), decided before any provider is contacted; pure decision, no prompt or HTTP
- `app/services/coverage_exception.rb` (+ `coverage_exception/history.rb`) — `CoverageException`: whether a two-section Automatic day gains one optional section, and which; pure. `History.for` is its one-query loader
- `app/services/shared_concept.rb` — `SharedConcept`: which reduced-tier concept both fixed sections take, from a host the day left free; pure
- `app/services/day_hosts.rb` — `DayHosts`: which kinds can tag a concept today, bucket and strict no-rung vocabulary; pure
- `app/models/real_source.rb` — `RealSource`: the curated registry of Code Gym's own methods and migrations a `code_review` may be grounded in, the per-user least-recently-seen pick over it, and the trace it reads back from `problem_set`. Closed lists, one class per excerpt kind — adding an entry is a line, adding a kind is a class
- `app/models/judge_verdict.rb` — `JudgeVerdict`: the judge's reply held to its closed vocabulary, the way `ProblemSetIngest` holds a problem set. A status outside three, an issue type or principle outside the lists, a rewrite of a field that is not prose, or blank evidence or reason is invalid output rather than a judgment. Pure; its specs need no database
- `app/models/concept_bucket.rb` — which vocabulary bucket a concept's history records under (architecture/plan_review/ambiguity_hunt are each language-independent; everything else buckets by the day's language)
- `app/models/kind_preferences.rb` — `KindPreferences`: a user's stated weight and exclusion bias over rotating kinds, as plain values `SectionRotation` takes instead of a `User`, so its specs need no database. `.none` is the untouched default; a stored value outside `MULTIPLIERS` reads back as that default rather than reaching `WeightedRoll`
- `app/models/kind_difficulty.rb` — `KindDifficulty`: a user's stated difficulty target and lock per section kind, as plain values the same way `KindPreferences` is. A level outside `LEVELS` reads as unset and a lock on an untargeted kind reads as unlocked, so an orphaned lock can never suppress easing the user did not validly choose. `#rung_for` is the rung a kind is pitched at today, target or skill level, and `RUNG_FOR_SKILL_LEVEL` the one reading of the skill scale as rungs
- `app/models/concept_hosts.rb` — `ConceptHosts`: which section kinds can host each (concept, bucket), derived from `ProblemSetIngest.selectable_vocabulary_for` across every `code_review` mode and the user's languages; read by `LadderCoverage` and the Progress page
- `app/models/ladder_coverage.rb` — `LadderCoverage`: which of the pairs `ConceptHosts` offers each kind already carry a ladder rung, for every kind whether or not it is targeted — callers filter for targets themselves
- `app/models/rung_ledger.rb` — `RungLedger`: the rung a user holds per concept, from stored responses and the `pitched_at` stamps; pure over the rows it is given
- `app/controllers/progress_controller.rb` — the `/progress` page: Learn's grouping, `RungLedger`'s standings, `ConceptHosts` for what is offered
- `app/models/exercise_section.rb` (+ `app/models/exercise_section/`) — the registry of section kinds (code_review, design_comparison, pattern, challenge, architecture, security_review, parsons_problem, plan_review, ambiguity_hunt, pseudocode_to_code); one class per kind answers which are fixed (`.fixed?`, each in a slot of its own, which `.slots`, `SectionRotation::OPTIONAL_SLOTS` and `MANDATORY_SLOT_COUNT` derive from), which are thirds, which are fourths, which vocabulary they draw from and how it narrows that list for generation (`.narrow_vocabulary`, given an optional rung), which fields are answer key (`.answer_key_fields`), what the provider boundary refuses (`.reject_unusable!`), how many judge retries a rejection buys (`.judge_retries`) and any extra judge instructions (`.judge_guidance`), how a resolved section is arranged after it is accepted (`.arrange!`), whether the judge solves it blind (`.judge_solve_options`, `.solve_matches_key?`), which show improved code, which scaffold their answer, and — via `.schema_fragment` / `.generation_guidance` — what the generation prompt says about them. `AiService` assembles those fragments and owns the language config; it no longer branches on section keys — or on kind identity — to build them. `.generation_guidance` takes a uniform context (`vocabulary:, label:, mode:, artifact:, test_framework:`) that every kind receives and each reads only its own part of; kinds that read none of the optional values absorb them with `**`. Adding a kind means adding a class here, not editing `AiService`.
- `app/helpers/answer_scaffolds_helper.rb` — the textarea pre-fill value and the `data-scaffold-labels` attribute the dashboard script reads, so the scaffold rule is stated once rather than per textarea
- `app/models/exercise_section/design_comparison.rb` — the second fixed kind: two working pieces, a server-rolled A/B order, the `pick:` answer encoding, its rung-aware vocabulary allowlist, and the judge's blind-solve facets
- `app/views/responses/bodies/_design_comparison.html.erb` / `answers/_design_comparison.html.erb` — the two pieces in their own disclosures; the pick fieldset, reason textarea and the script that writes the hidden answer, plus "What decides it" once reviewed
- `script/report_answer_positions.rb` (+ `script/answer_position_balance.rb`) — read-only count of where the better design-comparison piece was shown, totals only
- `script/solve_agreement.rb` — `SolveAgreement`: prints blind-solve agreement per model, rung and concept for `script/compare_models.rb`'s judge modes, never a solve or a key
- `app/services/claude_service.rb` / `gemini_service.rb` / `openai_service.rb` — per-provider HTTP call, connection, and model-per-purpose table
- `app/models/ai_provider.rb` — closed provider registry for dispatch, key detection and user validation; provider classes own the key patterns and environment restrictions
- `script/compare_models.rb` (+ `script/model_comparison.rb`) — standalone side-by-side run of one stored input through two Claude models, for manual reading. Billed to `ANTHROPIC_API_KEY`, writes no `ApiUsage` rows, and nothing in `app/` loads it. Two of its modes are for the judge: `judge <user_id>` drafts one day and prints each candidate's verdict with its evidence, and `judge_fixtures` runs the candidates over `spec/fixtures/judge/`, printing one row per fixture (an edit's row lists each issue type with the text it quotes, and a provider failure prints as an error row rather than ending the run), then valid-output rate, detection per principle, false rejections, keep fixtures kept unedited, and latency and cost per model from `LIST_PRICE_PER_MILLION`. Both judge modes also print blind-solve agreement (`SolveAgreement`) per model, rung and concept, with match or mismatch only, never a pick or a key. Two more modes are for the review prose judge: `review_prose <user_id> [limit]` runs stored reviews through the judge, and `review_prose_fixtures` runs the candidates over `spec/fixtures/review_judge/`, each printing rewrites beside their sources for a person to read. `review_calibration` grades the fixtures in `spec/fixtures/review_calibration/` on the production review route (see "Grading rubric")
- `app/models/rubric_check.rb` — `RubricCheck`: whether a graded review's rating agrees with the essential gaps it lists, under `AiService::RATING_RUBRIC`. Log-only and pure
- `spec/fixtures/review_calibration/` — sections with a complete, a partial and a missed answer each, read by `ModelComparison#review_calibration`; a fixture may add `extra_answers`, each with its own expected ratings, which are graded and matched outside the rank-order check (the design comparison's vague matching pick and sound other pick)
- `app/models/review_prose_verdict.rb` — `ReviewProseVerdict`: the prose judge's reply held to its closed lists, the structured-output schema, the projection the judge reads, and `#apply`, which stores the grader's original prose under `graded_prose`. Pure; its specs need no database
- `app/services/review_prose_judge.rb` — `ReviewProseJudge.enabled?`: the deployment-wide `REVIEW_PROSE_JUDGE` switch, off unless exactly `"1"`
- `spec/fixtures/review_judge/` — stored reviews that `ModelComparison#review_prose_fixtures` reads to compare candidates for the prose judge
- `spec/fixtures/judge/` — stored sections, each stating the verdict it expects (`reject`, `keep_or_edit`, or `keep`, which an edit does not satisfy), that `ModelComparison#judge_fixtures` reads to compare judge models. The broken ones include the Ruby `Thread` and frame-rate `code_review`s, the incidents this feature exists for; the hard-but-sound ones make a candidate's false rejections as visible as its detections. The six `design_comparison_*` fixtures cover a surface tell, a missing deciding fact, a junior section with two defensible pieces, a principal tradeoff, and junior and senior sections to keep; the ones a judge should keep carry `expected_better`, which the blind-solve report compares against
- `app/jobs/generate_daily_exercises_job.rb` — morning batch job + on-demand generation; persists failure state for the dashboard's status-polling to observe
- `app/controllers/responses_controller.rb` — auto-save (answers + rating), review, email-review endpoints
- `app/views/responses/_sections.html.erb` / `_section.html.erb` (+ `bodies/`, `answers/`) — the one loop over `DailyExercise#active_section_keys` and the one wrapper every section renders through, in both the answer-form and read-only states. Only the body and the answer area vary per kind, and each kind names its own partial for those (`ExerciseSection.body_partial` / `.answer_partial`), so adding a ninth kind is a body partial, an answer partial if it needs one, two `sections.<key>` locale strings, and whichever facets differ from the defaults — never a new branch in a template.
- `app/views/responses/_answered_sections.html.erb` — read-only render of a submitted day; shared by the dashboard's submitted state and every history entry. Its styles live in the layout's `<style>`, not a per-page block, precisely because it renders on both.
- `app/controllers/daily_exercises_controller.rb` — manual generate + once-daily regenerate
- `app/controllers/history_controller.rb` — paginated list of submitted sessions
- `app/controllers/sessions_controller.rb` — code request + verification, with rate limits
- `app/controllers/accounts_controller.rb` — Account page: log out + self-service deletion (anonymizes the user row in place)
- `app/models/user.rb` — auth methods, `recent_performance`, `language_for_today`, `anonymize!` / `active` scope, encryption
- `app/controllers/concept_references_controller.rb` — one action: the same concept explained another way, on demand from inside its own disclosure. Persists nothing; owns the cap, since there is no model data for it to live on
- `app/views/shared/_concept_reference_alternates_script.html.erb` — wires that control across the page, keying the framings already shown by reference id so one reference rendering several times still shares one cap
- `app/services/web_push_credentials.rb` — `WebPushCredentials`: the VAPID pair from ENV, and the single authority for whether push is configured at all
- `app/services/push_delivery.rb` — sends one notification to one endpoint, and deletes the endpoint when the push service reports it gone; the pruning is what keeps the job honest as iOS drops subscriptions
- `app/models/push_subscription.rb` — one browser install's endpoint. `.register!` upserts by endpoint, because the client re-subscribes on every launch
- `app/jobs/send_push_reminder_job.rb` — both reminder kinds, fanned out over one user's endpoints: `:ready` on the tick that generates the set, `:nudge` on later ticks of the same hourly cron, each enqueued by `GenerateDailyExercisesJob`'s cron branch rather than scheduled separately. Owns the nudge's copy, which varies with how far through the day is — untouched, partway, answered but unrated, or ready to submit
- `app/services/push_nudge_plan.rb` — the one authority for whether an hourly tick nudges: level, window, the not-submitted stopping rule, and the quiet period that keeps a half-finished day from being nudged while it is still being worked on. Pure, so its specs need no database
- `app/controllers/push_subscriptions_controller.rb` — enrol (JSON, since only script can call it) and un-enrol (an ordinary form post, so turning it off never depends on the machinery that turns it on)
- `app/models/display_preferences.rb` — `DisplayPreferences`: the closed lists of display choices, and what the layout renders for them (`<html>` attributes, the light palette's media, status bar and theme color)
- `app/assets/stylesheets/display.css` / `display_light.css` — text size, spacing and the reading font; the light palette. Linked only where `DisplayPreferencesHelper#display_stylesheets?` says so
- `app/views/api_keys/_display_preferences.html.erb` — the Display disclosure on Setup; applies a choice to the page at once, then saves it
- `app/views/shared/_pull_to_refresh.html.erb` — the installed app's pull-to-refresh indicator and gesture; inert outside standalone mode, which it reads from the layout's media query through the indicator's visibility
- `app/views/shared/_push_script.html.erb` — defines `window.CodeGymPush` and re-subscribes on launch; rendered from the layout ahead of `yield :page_scripts`
- `app/views/accounts/_push_reminders.html.erb` — the Account toggle. Its click handler is where the synchronous-gesture requirement lives
- `app/views/pwa/service-worker.js` — shows the notification. Every path ends in `showNotification`: Safari revokes the permission if a worker takes a push and displays nothing
- `app/services/schema_wait.rb` — blocks the worker's Railway pre-deploy step until the schema the Solid Queue supervisor boots against exists; waits rather than migrating, so migrations keep exactly one owner
- `app/services/preview_environment.rb` — single authority for "is this a Railway PR deployment," derived from `PREVIEW_APP`
- `app/services/preview_seed.rb` — demo content for PR apps; create-only, gated on `PreviewEnvironment.active?`
- `app/services/preview_mail.rb` — inline mail delivery in preview apps, gated on `PreviewEnvironment.active?`, so login never needs a worker
- `app/controllers/concerns/preview_auto_login.rb` — preview-only auto-login callback, registered only when `PreviewEnvironment.active?`
- `lib/boot/database_pool.rb` — `DatabasePool.size`: the pool `config/database.yml` asks for, sized for the judge fan-out on a Solid Queue worker (see "Railway Deployment"); outside the autoload path, because `database.yml` is read before `app/` can load
- `lib/boot/app_host.rb` — `AppHost.resolve`: `APP_HOST` then `RAILWAY_PUBLIC_DOMAIN`, with that order inverted on a preview app (see "Host resolution" above); outside the autoload path
- `app/services/fake_service.rb` — deterministic, zero-cost AiService provider for tests (`provider: "fake"`); overrides only `#call`/`#build_connection`, so every other AiService code path runs for real against its canned output. `AiService.for` refuses it outside a local environment.
- `app/controllers/learn_controller.rb` — the `/learn` library: lists every
  concept in the user's slice (assigned or not), the per-concept detail page,
  and three generation triggers: a one-concept `#prepare_concept`, a
  slice-wide `#prepare` backfill, and `#prepare_ladders`, which rewrites
  existing rows for the concepts behind a user's difficulty targets.
- `app/controllers/concerns/learn_scope.rb` — `LearnScope`: the user's slice
  of the vocabularies and the 404-on-unknown checks for a `:bucket`/`:concept`
  arriving from a URL, shared by `LearnController` and
  `ConceptDrillsController` — the same boundary rule `ProblemSetIngest`
  applies to provider output.
- `app/models/concept_drills.rb` — `ConceptDrills`: starts and stops drills,
  owns the concurrent cap and its reasoning, and answers what is drilled for
  the Learn pages. Writes only the two drill columns on `ConceptMastery` plus
  the one pause exit drilling is allowed to take.
- `app/controllers/concept_drills_controller.rb` — the four drill endpoints
  under `/learn`, per concept and per group; turns `ConceptDrills`' answers
  into a redirect and a flash and persists nothing itself.
- `app/views/shared/_featured_concept.html.erb` — the daily featured concept's
  one rendering, shared by the Learn tab and the dashboard; its styles live in
  the layout for that reason, like `responses/_answered_sections`
- `app/models/concept_book_sources.rb` — `ConceptBookSources`: the hand-curated
  book pointers a Learn page renders under "Where this comes from". Closed,
  array-valued, and never read by any prompt — extend it by adding a line
- `app/models/recognition_guide.rb` — `RecognitionGuide`: the cached "how to
  look for these" piece per recognition group, which groups have one, and
  what the prompt says each group is about.
- `app/jobs/generate_recognition_guide_job.rb` — writes one missing
  recognition guide; same permit and race handling as
  `GenerateConceptReferenceJob`.
- `app/models/concept_group.rb` — `ConceptGroup`: which display group a
  concept renders under on the Learn index, and the order groups appear in.
  Display-only, derived from `AiService`'s named vocabulary constants rather
  than restating their membership. Has no relationship to `ConceptBucket`,
  which decides where a concept's mastery history records, and must not
  acquire one.
- `spec/system/learn_filter_spec.rb` — pins that typing the humanized label
  actually shown on screen narrows the Learn list; the filter script matches
  against a rendered attribute a request spec never executes, so a mismatch
  between that label and the raw concept key was invisible to request specs
  and only caught here.
- `spec/system/` — real-browser specs (Capybara + capybara-playwright-driver) against the fake provider; `spec/support/system_test_helper.rb` registers the driver
- `config/recurring.yml` — Solid Queue cron schedule (8am UTC weekdays)
- `railway.toml` — build + deploy config for Railway
