# Code Gym Rails — Project Context for Claude Code

## What This Is

A team Rails app for daily personalized coding exercises. Each engineer logs in (emailed 6-digit code, no passwords), adds their own AI provider API key (Anthropic or Gemini), and gets an AI-generated problem set each morning tailored to their performance history. After submitting answers they can request an inline AI review, rate difficulty, and leave feedback — all of which feeds into the next day's problem generation.

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
  writes nothing, returning a `Result` instead. `ProblemSetIngest` is pure, so
  its specs need no database; `DailyPlan` composes two pure collaborators of
  its own — `SectionCount` (how many sections) and `SectionRotation` (which
  kind fills each) — whose specs need none, even though `DailyPlan` itself
  reads concept-mastery history to decide reinforcement and retention. Keep
  the collaborators that way.
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
  vocabularies grew; each was found by accident.
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
- **BCrypt** — login code digests
- **ActiveRecord Encryption** — encrypts each user's provider API key at rest
- **Railway** — hosting (web + worker services, postgres service)
- **Nixpacks** — auto-detected build from `railway.toml`

## Architecture

```
User logs in (emailed 6-digit code)
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
       2-4 sections, sized from recent completion: code_review is always
       present; Pattern of the Month, a rotating third (Coding Challenge /
       Architecture Decision / Security Review / Parsons Problem), and a
       rotating fourth (Plan Review / Ambiguity Hunt) each fill only when
       today's count and rotation choose them

User interacts:
  └→ ResponsesController#create      → auto-saves answers + difficulty rating +
       feedback text in one debounced fetch (idempotent). The rating renders at
       the end of the problem set and gates the Submit button — a set cannot be
       submitted unrated. A successful submit chains straight into #review from
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
       (feedback + concept tags are included in tomorrow's generation prompt)
       No review lands here any more; it is reached by navigation, by a
       post-login bounce back to a /history URL the user had already asked
       for, or by #index's own out-of-range correction. Each entry's
       problems fold by default and the newest entry's review opens, since the
       review is what someone opening the page came for.
  └→ AccountsController#show/destroy  → log out, or permanently delete (anonymize)
       the account in place while preserving all exercise/response/usage history
```

## Models

| Model             | Key fields                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| `User`          | email, name, skill_level, focus_areas (jsonb), api_key (encrypted), provider, language, adaptive_set_size (boolean, default true), anonymized_at (nullable — set on self-service deletion) |
| `DailyExercise` | user_id, date, problem_set (jsonb: code_review, pattern, a rotating third key, a rotating fourth key), language, generated_at, regenerated_at |
| `DailyResponse` | user_id, daily_exercise_id, answers (jsonb), section_ratings (jsonb, per-section self-rating), feedback_text, ai_review (jsonb), concept_tags (jsonb) |
| `ApiUsage`      | user_id, tokens_in, tokens_out, purpose, date                                                             |

## Key Design Decisions

- **Per-user API keys**: Each user provides their own Anthropic or Gemini key. Zero shared cost. The key's prefix (`sk-ant-` vs `AIza`/`AQ.`) selects `user.provider`; `AiService.for(user)` dispatches to the right subclass. Stored encrypted with `encrypts :api_key` (ActiveRecord Encryption) in the `users.api_key` column. The `ACTIVE_RECORD_ENCRYPTION_*` env vars are wired in via `config/initializers/active_record_encryption.rb` (Rails does not read them from ENV on its own); development derives throwaway keys from `secret_key_base` automatically.
- **Provider abstraction**: `AiService` is a template-method base class owning prompts, concept vocabularies, JSON parsing, and usage logging. Subclasses implement only `#call` and `#build_connection`. Adding a provider means adding a subclass, not editing the base.
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
  `ai_service_spec`'s "single-shot purposes" group drives the six other public
  entry points and asserts the history each one reaches `#call` with is empty. **This buys no cost reduction on either provider** — the merged duck
  system prompt runs ~500-600 tokens against `claude-sonnet-5`'s 1024-token
  cache minimum, so `cache_system` is deliberately not passed. What it buys is
  that a user typing `You:` into the duck box can no longer forge an assistant
  turn — but only on the Claude path, where `history` reaches the provider as
  real `messages`. This is the bullet's second Claude/Gemini asymmetry:
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
- **Meta-skill concepts**: `AiService::META_SKILL_CONCEPTS` (`reading_for_intent`, `spotting_unstated_assumptions`, `separating_symptom_from_cause`) name reasoning skills rather than technical topics, so `ConceptReference` delivers "how to think about this" on a real problem instead of on a tips page. They sit in both `RAILS_CONCEPTS` and `JS_CONCEPTS` like the data-modeling concepts, and for a structural reason rather than a preference: `ConceptBucket` dispatches on section key and never on concept, so a bucket of their own would require a section kind. Per-language mastery is the accepted cost; being outside `LANGUAGE_AGNOSTIC_VOCABULARIES` is the gain, since their reference then shows real code. Their hosts are `code_review` (non-schema modes), `pattern`, and `challenge` — every other kind draws a disjoint vocabulary and is excluded without an exclusion being written, and `parsons_problem` excludes them explicitly (`excluded_vocabulary_keys`) because a sequencing format has nothing to read. Because these are fuzzier than `n_plus_one`, `AiService#meta_skill_framing_guidance` adds one prompt line — stated once for all sections, named from the constant — requiring the section to still contain one findable issue that the concept only *frames*. No grading note changed; the generic rubric grades these, and it needs something missable to have been there. `AiService#can_host?` (given the concept, section key, and the day's generation language) derives third-slot retention hosting from `ProblemSetIngest.selectable_vocabulary_for` rather than restating it, so this exclusion — and the data-modeling one — is correct by construction rather than by coincidence.
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
- **The fourth slot**: an optional fourth `problem_set` key, alongside `code_review`/`pattern`/the rotating third — `DailyPlan::NO_FOURTH_TRACK` lets a day give it up entirely, and `AiService#fourth_reinforcement_line` reads as nil-able rather than assuming the key is always present. When present, it rotates 50/50 between `plan_review` (review a flawed implementation plan) and `ambiguity_hunt` (list what needs clarifying about a vague feature request). Each has its own closed vocabulary (`AiService::PLAN_REVIEW_CONCEPTS` / `AMBIGUITY_HUNT_CONCEPTS`) and its own `ConceptBucket` — language-independent, like `architecture`, so its mastery/reinforcement history never mixes with a programming-language bucket. `DailyPlan#for` decides the fourth slot's kind and its reinforcement/retention state on a track fully independent of the three-slot one, since the vocabularies can never mix. The slot holds exactly one concept (`DailyPlan::FOURTH_SLOT_CAPACITY`), so reinforcement is truncated to one and gives the slot up entirely when an overdue retention check claims it — never both. `ambiguity_hunt` also returns a hidden `planted_ambiguities` list — the answer key for grading coverage — which must never reach the rendered page, a pre-submission AI context (e.g. the duck thread), or log storage (`AiService#without_answer_key` strips it from the difficulty-diagnostics payload, the one place a whole `problem_set` is serialized); `plan_review`/`ambiguity_hunt`'s `plan_excerpt`/`request` fields are visible on screen and so are safe to include there. Since coverage grading has no meaning without that list, `ProblemSetIngest#reject_unusable_answer_key!` validates it at the provider boundary and raises `InvalidResponseError` when no usable entry came back — but only when `ambiguity_hunt` actually won the fourth slot, since an answer key nothing downstream will read is no reason to discard the rest of the day's sections — the one normalizer that can refuse rather than repair. A *wrong count* is not a failure: `ExerciseSection::AmbiguityHunt::PLANTED_COUNT` is the generator's target, but nothing downstream reads it (the review prompt lists the ambiguities, never counts them), so a short list still grades and rejecting it would discard the rest of a variable-length day over the likeliest deviation an LLM makes on a counted list. Long lists are truncated to `ExerciseSection::AmbiguityHunt::MAX_PLANTED`.
- **Which sections count**: `DailyExercise#active_section_keys` — code_review plus whichever of pattern/third/fourth today's plan chose, precedence-resolved for third and fourth — is the single authority for "how many sections does this day have." A day holds 2-4 sections; `SectionCount`/`SectionRotation` decide how many and which, but `active_section_keys` is still the one place anything downstream reads the answer. Every denominator (progress bar, `completeness`, history's count, the generation prompt's history line), the numerator (`DailyResponse#answered_sections`, via `DailyResponse#section_keys`), the submit gate, the answer/rating param slices, the duck-thread section guard, and the review fan-out derive from it. Never `problem_set.keys`, and never `answers.keys`: a payload can hold more third- or fourth-shaped keys than the page renders (`FakeService` holds all eight deliberately, and a provider can return an extra alternate), and a regenerated day can leave an answer behind for a section it no longer presents — counting either reports a section count the page never showed.
- **Adaptive sizing toggle**: `User#adaptive_set_size` (default true) is a hard override of the count only, not a reset to a default — `SectionCount.for` takes an early return to `ExerciseSection.slot_count` before any sizing logic runs when it's off, so there is no path from that logic to the output for that user regardless of how the sizing rule changes later. `SectionRotation`'s starvation-weighted kind selection still runs either way: it is not sizing, and it improves a full 4-section day too, so turning the toggle off does not skip the exercise-history query — only the sizing computation. A boolean is the right shape for a single-user-per-account app; if this app ever needed several floors per user, a floor preference would express the intent better than a single on/off switch.
- **Personalization loop**: `user.recent_performance(limit: 10)` returns the last 10 sessions with dates, sections answered, ratings, concept tags, and feedback text. This is embedded verbatim in the generation prompt so each day's exercises adjust to the user's trajectory.
- **One "answered" rule**: a section counts as answered when its text — minus any scaffold label lines the user never typed into — exceeds 10 characters. `DailyResponse.answered?` is the single source of truth: the progress bar, the teaching-hint lock, history, and the generation prompt all derive from it (the dashboard's inline script reads `ANSWER_MIN_LENGTH` and the labels from the server rather than restating the rule).
- **Answer scaffolds**: `pattern` and `architecture` ask for multi-part reasoning, so the generator returns an `answer_scaffold` — a short list of labels written for that specific question — inside the section's `problem_set` entry. A fresh textarea starts pre-filled with them; they are plain text in the same plain-string answer, so the user can delete or ignore them. Bounded on ingest (`ExerciseSection::MAX_SCAFFOLD_LABELS` / `MAX_SCAFFOLD_LABEL_LENGTH`) since it is provider output rendered into a form, and absent/unusable values fall back to the kind's `DEFAULT_SCAFFOLD`, so pre-scaffold rows render identically. `ResponsesController` normalizes on write: an answer that is nothing but labels stores as `""`, so every `answers[section].presence` reader — review prompt, history, `recent_performance` — sees what it saw before scaffolds existed.
- **One finish action**: the difficulty rating lives at the end of the problem set and autosaves on click, which enables the Submit button — disabled, with a visible nudge, until a rating exists. Answers and rating land in one `ResponsesController#create` call, and a successful submit fires the review from that same click — still a separate request, still exactly one review per day, just no second click to reach it. A rating is set-only: `#create` assigns it only on a valid enum value, so a stale autosave can never clear one. The dashboard requires JavaScript; rating, autosave, progress, and submit are all driven by the inline script, and there is no server-side rejection of an unrated submit because the UI cannot produce one.
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
  by `AiService::DIFFICULTY_ASSESSMENT_MAX_TOKENS` — which is derived from the
  largest valid reply and, by being passed at all, is what turns off the
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

- **Idempotent saves**: `ResponsesController#create` uses `find_or_initialize_by(daily_exercise:, date:)` so auto-saves never create duplicates.
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
  safe-area insets. `public/icon.svg` is the committed source of the icon;
  `icon.png`, `icon-192.png` and `apple-touch-icon.png` are rasterized from it.
  No service worker: nothing registers one, and iOS does not need one for
  standalone mode.

## Railway Deployment

- Project: `zesty-enthusiasm` (ID: `5b53ac62-bdb2-4e8d-a7f2-7a457b06ba4e`)
- Web service: `web-production-246e40.up.railway.app`
- Services: web, worker, postgres
- Web start command: `bundle exec puma -C config/puma.rb` (set in `railway.toml`; don't use `rails server -p $PORT` — Railway start commands run in exec form, so `$PORT` is never shell-expanded, while puma reads `PORT` from ENV)
- Worker start command: `bundle exec rake solid_queue:start` (set in `railway.worker.toml`; the worker service's Settings → Config-as-code file path must point at `/railway.worker.toml`, otherwise it inherits the web config and fails healthchecks)
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

- `app/services/ai_service.rb` — provider-agnostic base: prompts, concept vocabularies, JSON parsing, usage logging. Owns the difficulty scale's prompt text and `#assess_difficulty`'s deliberately narrow signature; `DailyResponse.usable_difficulty` owns what a storable/renderable assessment is, and is applied on write and again on read
- `app/services/problem_set_ingest.rb` — the generation boundary: holds concepts to their closed vocabulary, bounds scaffolds and diagrams, rolls the parsons scramble, and rejects an unusable ambiguity-hunt answer key, and logs a section the day never asked for. Writes nothing to the database — off-vocabulary concepts come back on the `Result` for `AiService` to record, so a rejected set structurally cannot leave a `SuggestedConcept` row behind, and its specs need no database. Not side-effect free, though: `warn_unrequested_sections!` logs.
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
- `app/controllers/sessions_controller.rb` — code request + verification, with rate limits
- `app/controllers/accounts_controller.rb` — Account page: log out + self-service deletion (anonymizes the user row in place)
- `app/models/user.rb` — auth methods, `recent_performance`, `language_for_today`, `anonymize!` / `active` scope, encryption
- `app/controllers/concept_references_controller.rb` — one action: the same concept explained another way, on demand from inside its own disclosure. Persists nothing; owns the cap, since there is no model data for it to live on
- `app/views/shared/_concept_reference_alternates_script.html.erb` — wires that control across the page, keying the framings already shown by reference id so one reference rendering several times still shares one cap
- `app/services/preview_environment.rb` — single authority for "is this a Railway PR deployment," derived from `PREVIEW_APP`
- `app/services/preview_seed.rb` — demo content for PR apps; create-only, gated on `PreviewEnvironment.active?`
- `app/services/preview_mail.rb` — inline mail delivery in preview apps, gated on `PreviewEnvironment.active?`, so login never needs a worker
- `app/controllers/concerns/preview_auto_login.rb` — preview-only auto-login callback, registered only when `PreviewEnvironment.active?`
- `lib/boot/app_host.rb` — `AppHost.resolve`: `APP_HOST` then `RAILWAY_PUBLIC_DOMAIN`, with that order inverted on a preview app (see "Host resolution" above); outside the autoload path
- `app/services/fake_service.rb` — deterministic, zero-cost AiService provider for tests (`provider: "fake"`); overrides only `#call`/`#build_connection`, so every other AiService code path runs for real against its canned output. `AiService.for` refuses it outside a local environment.
- `spec/system/` — real-browser specs (Capybara + capybara-playwright-driver) against the fake provider; `spec/support/system_test_helper.rb` registers the driver
- `config/recurring.yml` — Solid Queue cron schedule (8am UTC weekdays)
- `railway.toml` — build + deploy config for Railway
