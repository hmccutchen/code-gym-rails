# Code Gym Rails — Project Context for Claude Code

## What This Is

A team Rails app for daily personalized coding exercises. Each engineer logs in (emailed 6-digit code, or an authenticator app once they turn one on; no passwords), adds their own AI provider API key (Anthropic, Gemini or OpenAI), and gets an AI-generated problem set each morning tailored to their performance history. They answer sections and rate difficulty before submitting. Submission requests an inline AI review; the submitted work and review feed into the next day's problem generation.

## Git Workflow

All changes are made on a feature/dev branch, never directly on `main`. Create (or switch to) a branch before touching any files, and open a PR into `main` when the work is ready for review.

A push runs the unit suite through the pre-push hook (`lefthook.yml`), so give
`git push` a timeout of at least five minutes, and don't push while another
spec run on this machine is using the test database.

**Every PR gets an intent log entry before it merges.** Use the `intent-log`
skill (`.claude/skills/intent-log/SKILL.md`): once the PR is open, append the
day's entry to your own `docs/intent/<github-login>.md`, tag it with the PR
number, run the skill's `compose.rb` and `check.rb`, and commit the result to
the PR's branch. The entry records what you asked for and why, read from your
own prompts, so a reviewer can tell your decisions from the agent's. Run it on
the PR's branch, not a detached HEAD, and with `gh` signed in, since `check.rb`
reads the PR list from GitHub. It answers only for PRs you opened since the date
in `docs/intent/_since`. Never edit `docs/intent-log.md` by hand, since
`compose.rb` generates it.

**Every PR gets two reviews once the implementation is done, each run by a
separate agent.** After the suites pass and before the PR is marked ready,
start a subagent for each review. The session that wrote the code has
already decided it is right, so it doesn't review its own work.

- **Critical review:** the `critical-reviewer` agent
  (`.claude/agents/critical-reviewer.md`) judges the change's design as a
  whole, using the whole repository.
- **Layered-design review:** `/layered-rails:review` checks layer boundaries,
  callbacks, concerns and where each class lives. It comes from the
  `layered-rails` plugin, which each developer installs. If it isn't
  installed, say so in the PR rather than skipping the review silently.

**Findings are checked before any code changes.** Hand both reviews' findings
to another fresh agent. It checks each finding against the code and reports
it as confirmed, with the file and line or a failing spec that shows it, or
as rejected, with the reason. Fix only confirmed findings, test-first. When a
finding would change the design, the person who asked for the work decides
before anything changes. Out-of-scope findings become GitHub issues. Post a
PR comment listing what was fixed, what was rejected and why, and which
issues were opened. Reviewers can run specs, and two runs sharing the test
database fail falsely, so don't run the suite while a review agent is
working.

## Code Style

### Comment rules — never ignored

These rules hold in every file, in every change, with no exceptions for a
deadline or a "temporary" comment. The one exemption is a skill vendored under
`.claude/skills/`, which keeps the comments it came with; neither RuboCop nor
`bin/comment-check` scans that folder. CI enforces the first three, so a
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
  `docs/`. A design decision keeps a short entry in its area's
  `.claude/rules/` file and its full text in `docs/decisions/`. The reasoning
  behind one file's code lives in
  `docs/code-notes/`, at the file's own path with `.md` in place of its last
  extension (`app/clients/ai_service.rb` →
  `docs/code-notes/app/clients/ai_service.md`;
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
The app's copy is `PromptStandards::PLAIN_LANGUAGE_STANDARD`, shared by the
prompts that explain, reframe, answer follow-ups on, or grade an engineer's
work. `spec/prompts/prompt_standards_spec.rb` fails when the list below drifts
from it.

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
  `DailyResponse.answered?`, one class per prompt family).
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
decisions, not defaults that drifted into place: template method for
providers, one class per prompt family, one request value per provider call,
the section-kind registry, pure decision objects, single authority per fact,
one prompt line per vocabulary group, provider calls as callables,
outcomes at the HTTP edge, claims and lock order, the server decides and the
page shows its answer, page behavior as Stimulus controllers, one way to send
a request, domain data kept off provider classes, and folders by layer.
`.claude/rules/patterns.md` states each one and loads with any file under
`app/`, `lib/`, `spec/`, `config/`, `script/` or `db/`. Deviating from one is
allowed, but the PR description must say why; an unexplained departure is
treated as an oversight and blocks review.

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
- No read across an isolation boundary. Each is pinned by a spec:
  - Nothing under `app/models`, `app/services`, `app/jobs`, `app/prompts` or
    `app/clients` reads trial state, apart from the trial and key models and
    `User` (`trial_isolation_spec`, which names them).
  - Generation, review, both judges, `ConceptMastery` and `KindDifficulty`
    never read track or suggestion state (`level_suggestion_isolation_spec`).
  - `SectionKindGuide` and `ConceptBookSources` never reach a provider prompt.
  - `#assess_difficulty` is handed no response or history, and
    `#explain_concept_differently`, `#generate_concept_reference` and
    `#generate_recognition_guide` no exercise or response; their signatures
    hold this. `ConceptReference::REFERENCE_FIELDS` stays unwidened.
  - Answer-key fields (`ExerciseSection.all_answer_key_fields`) never reach
    the page, a pre-submission AI context or a log before review.
  - No page shows or implies `ConceptMastery` tier.
  - No model names `AiService` or a provider class; `.claude/rules/patterns.md`
    ("Domain data stays off provider classes") says which one may
    (`app_source_spec`).
- New methods stay under 25 lines (excluding heredoc bodies), new `app/` files
  under 300 — or the PR says why not. Nothing enforces this mechanically;
  `Metrics` is disabled.

**What CI does and doesn't tell you.** The workflow runs RSpec, system specs,
RuboCop, `bin/comment-check`, `archspec check`, Brakeman, and `importmap audit`. It does *not* run a Ruby dependency
CVE audit (`bundle-audit` is not installed) or any complexity check, and this
repository has no branch protection — so no check gates a merge. The local
hooks (`lefthook.yml`) run the same checks, except the system specs, before a
push, but anyone can skip them. CI is
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
- **Railway** — hosting (web + worker services, and a `Database` service running Railway's Postgres 18 template)
- **Docker** — Railway builds the image from the `Dockerfile`, as its build logs show, although `railway.toml` still names Nixpacks

## Architecture

- Each engineer signs in with an emailed 6-digit code, or an authenticator
  app in its place once it is on, and stores their own
  Anthropic, Gemini or OpenAI key, encrypted; the key's prefix sets
  `user.provider`, and `AiService.for(user)` dispatches on it.
- At 8am on weekdays the Solid Queue cron runs `GenerateDailyExercisesJob`,
  which builds the day's set from the user's recent performance. A dashboard
  opened with no set generates one on demand and polls `GET /dashboard/status`.
- A day holds 2-4 sections: `code_review` and `design_comparison` always planned, and
  `DaySize` and `SectionRotation` fill the rest.
- `ResponsesController#create` autosaves answers and ratings; a successful
  submit chains into `#review` (`ResponseReview`), which lands back on the
  submitted dashboard with the review in place.
- `/history` shows every submitted day, `/learn` is the concept library, and
  `/progress` shows the rung each concept is held at.

`.claude/rules/request-flow.md` has the full flow and `.claude/rules/models.md`
the model table.

## Area rules

The design decisions live in path-scoped files under `.claude/rules/`. Each
loads when Claude reads or edits a file matching its `paths:` globs; read one
directly when a task touches its area before any matching file is open. The
full reasoning behind an entry is in the `docs/decisions/` doc it names.
`config/locales/en.yml` holds keys several areas own; read the rule for the
area whose copy you change.

- `.claude/rules/generation.md`: the generation prompt and pipeline, the judge, the ingest boundary, section kinds, concept vocabularies.
- `.claude/rules/planning.md`: how a day's size, kinds, reinforcement and retention checks are chosen, user preferences that steer them, pausing.
- `.claude/rules/levels.md`: the welcome track choice, the skill level setting, per-kind level suggestions.
- `.claude/rules/providers.md`: provider subclasses and routing, API keys, request limits, usage rows, truncation, failure wording, log filtering.
- `.claude/rules/answers.md`: what counts as answered, autosave, offline saving, submit, folding, the reviewed-response invariant.
- `.claude/rules/review.md`: the grading rubric, the review prose judge, the post-hoc difficulty note.
- `.claude/rules/learn.md`: the Learn tab, concept references and guides, hand-written text, the Progress page, the weekly featured concept.
- `.claude/rules/accounts.md`: emailed-code login and its limits, invite codes and trials, preview apps, host resolution.
- `.claude/rules/pages.md`: history paging, server-side highlighting, the home-screen app and pull-to-refresh, display preferences, push reminders.
- `.claude/rules/patterns.md`, `request-flow.md`, `models.md`, `tests.md`,
  `deployment.md`: the adopted patterns, the request flow, the model table,
  test setup, and Railway deployment.

## Local Development

```bash
bundle install
bin/rails db:prepare  # creates the database and loads the schema
bin/dev               # starts the web server only
bin/jobs              # optional: Solid Queue and the recurring schedule
```

`bin/setup` also installs Prettier for `CodeFormat` and the git hooks in
`lefthook.yml`, which run CI's checks before a commit and before a push.
`docs/code-notes/lefthook.md` says which run when and how to skip them.
Prettier needs Node and npm. On an older checkout, run
`npm --prefix vendor/prettier ci` and `bundle exec lefthook install` once.

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

**What to run when.** During a TDD step, run the spec file you are changing.
When a task is done, run the unit suite once
(`bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`). Before opening
a PR, run `spec/system` once. CI runs everything on every PR. A diff that
touches one of the shared authorities named in
`.github/copilot-instructions.md` still runs the full unit suite, not just the
changed file. After a failing run, `bundle exec rspec --only-failures` re-runs
only what failed; RSpec records each example's result in `spec/examples.txt`
(gitignored).

Setup, parallel runs, system specs and the spec support defaults are in
`.claude/rules/tests.md`, which loads with any file under `spec/`.

## File Map

`docs/file-map.md` lists what each file does.
