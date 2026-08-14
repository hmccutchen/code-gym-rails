# Code Review Guidelines

These guidelines exist to catch real problems before they ship, not to enforce
style preferences.

## What this project is

A Rails 8 app that generates personalized daily coding-practice exercises via
an AI provider (Anthropic or Gemini), reviews submitted answers, and adapts
future exercises based on performance history. Each user brings their own
encrypted API key — there is no shared/admin key anywhere in this codebase.

Stack: Rails 8.0.5, PostgreSQL, Solid Queue (background jobs, no Redis),
Faraday for all AI provider HTTP calls (not the official Anthropic SDK, by
design — this keeps provider logic swappable). No JS framework — inline
`<script>` tags are the established convention for client-side behavior.

## How to review

Every check below is written as a question with a findable answer. Answer each
one against the diff. "Checked" is not an answer; "no new provider-facing input
in this diff" and "`ProblemSetIngest#normalize_concepts!` gained a branch, and
it validates" both are.

**A review that finds nothing must say what it looked for and why each check
passed.** Name the specific code you examined and the specific reason it
satisfies the check. A review that lists the categories and reports no findings
without naming what was examined is not a review — it is an acknowledgement,
and it is the failure mode these guidelines exist to prevent.

If a check does not apply to a diff, say so and why ("no new class exceeds the
threshold — the diff adds one 6-line method"). Silence on a check reads as
unexamined.

**Blocking vs. nit.** Anything marked BLOCKING must be resolved before approval
regardless of how small the rest of the diff is. Style nits may be left
unresolved on an approved PR.

## Structural checks

These encode invariants this codebase has already paid to establish. Each names
the authority that owns the rule, so a violation is demonstrable rather than a
matter of taste.

**Does this PR add a branch on section kind, provider, or concept bucket in
shared code?** BLOCKING. The stated invariant is that adding a kind means
adding a class, not editing shared code. `ExerciseSection` and its subclasses
own per-kind facts; `AiService` subclasses own per-provider facts;
`ConceptBucket` owns which vocabulary a concept records under. A `case`/`if` on
`section_key`, `kind`, `provider`, or a bucket name inside `AiService`,
`DailyPlan`, a controller, or a shared partial is a violation — call it out as
blocking, not as a passing note. The fix is a method on the kind/provider
class, not a branch at the call site.

**Does any rule now appear in two places? Name both.** BLOCKING when the two
can disagree. Every piece of knowledge has one authoritative home. Precedent:
the concept-bucket rule appeared six times in three different shapes before
`ConceptBucket` consolidated it — that is the cost this check exists to
prevent. If the diff adds a second place, name the file and line of both and
say which should be the authority.

**Does any denominator, count, or threshold get hardcoded where an existing
authority already computes it?** BLOCKING. Precedent: the literal `3` appeared
in five places before `DailyExercise#active_section_keys` became the single
authority for how many sections a day has. Before accepting any numeric literal
that describes the data, search for an existing method that derives it. Current
authorities include `active_section_keys` (section count and identity),
`DailyResponse::HISTORY_PAGE_SIZE`, `ExerciseSection::MAX_SCAFFOLD_LABELS`,
`DailyPlan::FOURTH_SLOT_CAPACITY`, and `AmbiguityHunt::MAX_PLANTED`. Counting
`problem_set.keys` or `answers.keys` instead of `active_section_keys` is the
same violation wearing a different hat.

**Does any new class or method exceed the size threshold?** A method over **25
lines** (excluding heredoc bodies) or a new file in `app/` over **300 lines**
must be justified in the PR description or split. These numbers are drawn from
this repo: across 282 methods in `app/`, the 95th percentile is 31 lines and 20
methods exceed 25.

Two honest caveats. First, this is **not machine-enforced** —
`rubocop-rails-omakase` disables the entire `Metrics` department, so no CI job
measures it and the reviewer is the only enforcement. Second, several existing
files exceed these numbers, most visibly `app/services/ai_service.rb` at 1303
lines with a 156-line `build_exercise_prompt`. That method is five heredocs of
prompt text rather than logic, which is why the threshold excludes heredoc
bodies. The threshold governs new and substantially rewritten code; it is not a
standing demand to refactor what is already there.

**Does any new provider-facing input skip boundary validation?** BLOCKING.
Provider output is untrusted input. `ProblemSetIngest` is the generation
boundary and the place that holds it to a closed vocabulary, bounds scaffolds
and diagrams, and rejects an unusable ambiguity-hunt answer key. Anything read
out of a provider response and rendered, stored, or branched on must pass
through a normalizer there. Validate at the boundary so everything downstream
can assume clean data — a `.presence` guard at the render site is not boundary
validation.

## Comments

**Does a comment restate the line beneath it?** Cut it. **Does it state a WHY
the code cannot?** Keep it — a hidden constraint, a workaround, an invariant a
future reader would otherwise break.

Some comments read as obvious but carry something real and must survive: a
non-RESTful route, a partial's required locals, an abstract method's contract,
and a deliberately empty branch where the emptiness *is* the behavior. The test
runs both directions — if deleting it would let someone reintroduce a bug, it
stays; if it only repeats the line beneath it, it goes.

**Is any comment now false?** BLOCKING. A stale comment is worse than either a
missing or a redundant one. If the diff changes behavior a nearby comment
describes, the comment changes with it.

Note when auditing mechanically: `#{...}` interpolations and `#` lines *inside*
a heredoc are content, not comments — in `AiService` they are prompt text sent
to the provider, and in `FakeService` canned provider output.

## Correctness

**Does new behavior have a corresponding test?** BLOCKING. Request, model,
service, or job spec, matching whatever the touched code already uses. A PR
that adds behavior with zero coverage is blocked, not nitted.

**Does the diff weaken or delete an existing assertion?** BLOCKING unless the
reasoning is stated explicitly in the PR description. Changing an assertion to
make a test pass is the single easiest way to ship a regression.

**Would the new test fail if the behavior it covers were reverted?** A test
that passes against both the old and new implementation asserts nothing. Where
this is not obvious from reading, say so and ask.

## Security

**Does new user input reach a query, shell command, file path, or rendered
view without validation?** BLOCKING. Raw string interpolation into SQL or a
shell command is always blocking.

**Does the new controller action check authorization, not just
authentication?** BLOCKING. `current_user` being present is not authorization —
confirm the user is allowed to access that specific record.

**Can an API key reach a log, a view, or an error message?** BLOCKING. Provider
keys pass only through the encrypted `api_key` column and the request headers
built in `app/services/*_service.rb`. Never approve a change that reads or
transmits another user's `api_key`, email, or personal data without an
explicit, visible authorization check.

**Does a hidden answer key stay hidden?** BLOCKING. `planted_ambiguities` is
grading data and must never reach a rendered page, a pre-submission AI context,
or log storage. `AiService#without_answer_key` strips it from the one place a
whole `problem_set` is serialized.

## Performance

**Does any loop trigger a query per iteration?** Check for a missing
`includes`/`preload`. This project's data is small — one row per user per
weekday — but flag it regardless of current volume; the habit is the point.

**Does any new `where`/`find_by` hit an unindexed column?**

**Is a synchronous external HTTP call added directly in a controller action?**
The convention is Solid Queue for anything provider- or email-facing, unless
blocking is explicitly by design (the AI review and anonymize-on-delete flows
are the standing exceptions).

## Architecture — this project's conventions, not generic advice

**Does AI-calling code bypass `AiService.for`?** BLOCKING. Shared logic
(prompt-building, schema, error types) lives in `ai_service.rb`; subclasses own
only provider-specific HTTP and auth. A controller building its own Faraday
request is a violation.

**Can a concept tag bypass normalization against the closed vocabulary?**
BLOCKING. `RAILS_CONCEPTS`, `JS_CONCEPTS`, and the rest are deliberately closed
Ruby constants — not free-form strings, not a database-editable list. This
keeps concept history comparable over time; it is intentional, not an
oversight.

**Does any new "today" computation resolve in the user's timezone?** Anything
user-facing must go through the existing zone-wrapping convention
(`ApplicationController#use_time_zone`), never assume server/UTC time.

**Does the diff touch load-bearing auth or mail infrastructure?**
`SessionsController`, `ApplicationMailer`, and `config/environments/*.rb`
mailer settings get extra scrutiny and must not be bundled into an unrelated
feature PR.

**Does the diff fork a second copy of existing view logic?** BLOCKING. If a
rendering already exists for "show one day's response + review," reuse it.

## Repo-specific style

**Predicate methods** end in `?` and follow the existing `reviewed?`/
`submitted?` naming. Check for an existing method before adding one that
duplicates its logic.

**jsonb columns** (`problem_set`, `ai_review`, `concept_tags`) are the
established pattern for exercise/response data that varies in shape. Don't
introduce a normalized table for data naturally scoped to one user's one day
unless there is a stated reason jsonb won't work (e.g. data shared across
users, like `ConceptReference`).

**Old data must never break on a new field.** BLOCKING. Any new jsonb key must
be read nil-safely (`.presence`, safe navigation) everywhere it is displayed or
used in logic. Flag any read that assumes a new field exists on historical rows.

## Failure handling

**Does every new provider call have an error path?** BLOCKING. Rate limits,
auth failures, and malformed JSON are ongoing realities of this integration,
not edge cases.

**Does a failed background generation stay invisible to the user?** Background
jobs calling a provider log and move on; a failure must never surface as a
user-facing crash unless the PR explicitly says otherwise.

## Reviewing the pull request itself

**Does the PR description claim something the diff doesn't do?** BLOCKING —
say so explicitly before evaluating the diff on its own terms. This includes
claiming a test exists that doesn't, claiming a check passed that wasn't run,
and describing a behavior the code doesn't implement.

**Does the PR deviate from an established in-repo pattern without saying why?**
The patterns this codebase has deliberately adopted are listed under "Standards
and Authorities" in `CLAUDE.md`. Deviating is allowed; doing it silently is
not.

**Note on CI.** The workflow runs RSpec, system specs, RuboCop, Brakeman, and
`importmap audit` — but this repository has no branch protection, so none of
them gate a merge. There is no Ruby dependency (CVE) audit and no complexity
check at all. Treat CI as advisory signal, not as a guarantee that anything was
verified, and never approve on the assumption that a check would have caught it.
