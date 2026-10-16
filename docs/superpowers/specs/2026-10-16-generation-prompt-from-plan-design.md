# Build the generation prompt from the plan as a whole

Status: draft for review. Nothing is implemented.
Date: 2026-10-16. Checked against `origin/main` at `3c96c35`.
Revised after tracing the callers, diagnostics, curated source pool and tests.

## Goal

The generation prompt is built by `AiService#build_exercise_prompt` from
eighteen keywords. The plan's result reaches those keywords by being copied
field by field into a hash and then splatted. A new plan field means editing
three places, the builder's defaults query the database, and specs reach the
builder through `send`.

After this change the prompt is built by a public class, `GenerationPrompt`,
from the plan and the other drafted inputs as whole values. No default
queries the database. The prompt can be built from a plain `DailyPlan::Result`
with no persisted rows and no `send`. A required retention-annotation callable
keeps one curated source method in place; the reason is below. Every existing
prompt snapshot stays identical byte for byte.

This is a pure refactor. No prompt text, no ordering and no whitespace
changes. Refactor B (one request value per provider call) is a separate PR
with its own spec after this one merges.

## Review findings that change this design

These are implementation blockers in the original proposal, not defects
introduced into the running app by this documentation-only PR.

| Finding | Current evidence | Required correction |
|---|---|---|
| Moving retention annotation changes the real-source pool | `RealSource::APPLICATION_CODE` includes `app/services/ai_service.rb#annotate_retention_concept`. `RealSource::Method#text` reads that definition; `.pick` skips an unresolved entry. Its path/method id also keys persisted source history | Keep that method's definition, body and location unchanged, with `can_host?`, and pass its bound callable to the renderer. Do not replace it with a short delegator, delete the entry, or repoint it in this refactor |
| Difficulty rendering has a production caller outside the template | `AiService#kind_difficulty_diagnostics` calls `kind_difficulty_guidance(...).length` during `finish_generation` | Give the difficulty block one shared renderer and migrate diagnostics with the template. Leaving this caller behind breaks generation after the paid call |
| The proposed script override becomes process-wide | `ForcedConceptDrafts#draft` currently prepends onto one service instance. Prepending onto `ConceptGuidance.singleton_class` affects every caller and cannot be undone by removing a method | Keep the override on a prompt instance created for that service, never on the shared class or module |
| Existing snapshots do not cover current day sizes | The 72 combinations leave `pattern: :pattern` and both rotating slots present: `ExerciseSection.for_plan` returns five kinds, while `SectionRotation` plans at most `ExerciseSection::MAX_SECTIONS` (four) | Keep those legacy snapshots unchanged and add valid two-, three- and four-section shapes, including absent optional slots and `design_comparison` |
| Mechanical `send` replacement misses other dependencies | `ai_service_spec.rb` also has one expectation and two overrides of `build_exercise_prompt`, plus a `locked_difficulty_line` send used by the exhaustive budget test | Migrate these to captured provider arguments and the shared difficulty renderer; do not delete or weaken their assertions |

The smaller-interface extraction is still worthwhile. Keeping the keyword
hash would leave the copy points intact. Moving every helper and repointing
the curated source entry would shorten `AiService` further, but would change
the generated source instructions and source-history identity. This design
chooses whole plan inputs, one shared difficulty renderer, and a narrow
callable for the source-sensitive helper. Moving that helper later needs its
own explicit source-identity and prompt-change decision.

## What drifted since the earlier review

The review's notes were written against an older `ai_service.rb`. Two PRs
moved things since: #342 took the review fan-out out of `AiService`, and #396
reworked the difficulty block. The file is now 1,992 lines.

| Claim in the review | On `main` today |
|---|---|
| `exercise_prompt_options` at ~1646-1659 | `app/services/ai_service.rb:815-826`, 12 lines |
| `build_exercise_prompt` at ~2171-2370, about 200 lines | `app/services/ai_service.rb:1159-1325`, 167 lines |
| `DailyPlan::Result` has ~16 fields | Exactly 16 (`app/services/daily_plan.rb:3-6`) |
| ~18 keywords on the builder | Exactly 18 keywords plus two positional parameters (`user`, `language`) |
| Defaults query the database | Still true: `history: user.recent_performance` (line 1161) and `reinforcement \|\| user.concepts_needing_reinforcement(...)` (line 1185) |
| The fourth slot's retention block copies the other slots' block | Same shape, different text and a different annotation rule. See "Retention-block duplication" below |
| ~77 `send` calls reach the builder from specs | 77 in `spec/services/ai_service_spec.rb`, 1 in `spec/requests/security_audit/hardening_targets_spec.rb`, and 1 multiline call in `generation_prompt_characterization_spec.rb`: 79 textual call sites, with the last generating many examples. Also migrate the expectation and two method overrides, not just sends |
| The concept-vocabulary cleanup ("card 1") should land first | Done. PR #334 (`9c0aa45`) moved every list to `ConceptVocabulary` and left the prompt unchanged. Nothing in this refactor waits on it |
| For B: the "additive keyword" note lives in CLAUDE.md | After #401 split CLAUDE.md, the note is in `docs/decisions/conversational-calls-send-real-turns.md` and `docs/decisions/two-stage-generation.md` ("fourth additive keyword", "fifth"). B's PR updates those two docs and `.claude/rules/providers.md`, not CLAUDE.md |
| For B: `#call` has 9 keywords, `call_and_log` has 14 call sites | Both still true. `ApiUsage::PURPOSES` lists 14 purposes. `FakeService#call` still picks replies by matching the prompt text (13 text matches) |

## The three copy points today

`DailyPlan.for` builds a `Result`. `draft_exercise` (line 780) turns it into a
hash with `exercise_prompt_options` (copy 1), splats the hash into
`build_exercise_prompt` (copy 2, the keyword list), and stores the hash on
`Draft#prompt_options` so `retry_section` (line 846) can splat it again with
`ladders` replaced and `only:`/`fixed_concept:` added (copy 3).

| `DailyPlan::Result` field | In `exercise_prompt_options`? | Builder keyword | Where the prompt uses it |
|---|---|---|---|
| `pattern` | yes | `pattern:` | kinds (via `ExerciseSection.for_plan`), schema |
| `third` | yes | `third:` | kinds, schema |
| `reinforcement` | yes | `reinforcement:` | "Concepts needing reinforcement" line |
| `due_checks` | yes | `due_checks:` | retention block (hosting-annotated) |
| `established` | yes | `established:` | established block |
| `fourth` | yes | `fourth:` | kinds, schema, fourth reinforcement line, fourth retention heading |
| `fourth_reinforcement` | yes | `fourth_reinforcement:` | fourth reinforcement line |
| `fourth_due_checks` | yes | `fourth_due_checks:` | fourth retention block |
| `fourth_established` | yes | `fourth_established:` | fourth established block |
| `code_review_mode` | yes | `code_review_mode:` | hosting test, section guidance for `code_review` |
| `code_review_source` | yes | `code_review_source:` | section guidance |
| `scenario_flavor` | yes | `scenario_flavor:` | scenario flavor line |
| `shared_concept` | yes | `shared_concept:` | shared concept line (skipped on a retry) |
| `coverage` | no | | diagnostics and persisted `plan.notes`, not prompt text |
| `waiting_checks` | no | | logging only |
| `size` | no | | diagnostics and persisted `plan.notes`, not prompt text |

Three values are not plan fields but travel through the same hash:

| Value | Source in `draft_exercise` | Builder keyword |
|---|---|---|
| `history` | `user.recent_performance` (one call; response query plus exercise preload when populated) | `history:` |
| `difficulty` | `KindDifficulty.for(user)` | `difficulty:` |
| `ladders` | `ladders_for(...)` (queries `ConceptReference`) | `ladders:` |

Two keywords exist only for a retry: `only:` and `fixed_concept:`.

The `Draft` value already carries `plan`, `history`, `difficulty` and
`ladders` as fields of its own, next to `prompt_options`. The hash is a
second copy of four fields the draft already has.

## Defaults that hit the database, and who relies on them

Two defaults query:

- `history: user.recent_performance` (line 1161). Runs `recent_daily_responses`
  and walks each exercise's problem set.
- `reinforcement: nil`, then `user.concepts_needing_reinforcement(exclude_buckets: DailyPlan::FOURTH_BUCKETS)`
  (line 1185).

Who relies on them:

- `draft_exercise` and `retry_section` never do. Both pass every value.
- Of the 77 builder calls in `ai_service_spec.rb`, 2 pass `history:` and 14
  pass `reinforcement:`. The other 75 and 63 take the default. The spec's
  `user` is a persisted `User.create!` with no exercises, so both defaults
  return `[]`. The `allow(user).to receive(:concepts_needing_reinforcement)`
  stubs in that file belong to `generate_exercise` examples, where `DailyPlan`
  is the reader, not the builder.
- `hardening_targets_spec.rb:94` calls the builder with no keywords at all on
  a persisted user. Both defaults run and return `[]`.
- `generation_prompt_characterization_spec.rb` passes both explicitly, so the
  snapshots never touch the database.

Other defaults are pure and stay in the test helper, not in app code:
`third: :challenge`, `pattern: :pattern`, `fourth: :plan_review`,
`code_review_mode: :application_code`, `scenario_flavor: :general`,
`difficulty: KindDifficulty.none`, `ladders: {}`, and the empty lists. None
of these defaults is needed by a production caller: `DailyPlan.for` sets every
field. Individual values can match production, but the defaults together
describe the legacy five-kind shape, not a current planned day.

The builder also reads `user.name`, `user.skill_level` and
`user.focus_areas`. Those are attributes of an object the caller holds, not
queries, and an unpersisted `User.new` serves them (the characterization
spec does this). They stay.

### State ownership and lifetime

`DailyPlan.for` owns selection, ordering, capacity, source and scenario rolls.
`User#recent_performance` owns history ordering and answered-section data;
`KindDifficulty.for(user)` reads targets and locks; `ladders_for` loads and
truncates complete `ConceptReference` ladders. The renderer must not repeat
any of those reads or decisions, query associations, consult the clock, roll
randomness, or mutate supplied values.

`DailyPlan` materializes the concept lists before returning its result.
Supply materialized collections to the renderer, not lazy relations. The
claim here is no database access during rendering, not no filesystem access:
`CodeReview.generation_guidance` calls `RealSource#instruction`, which reads
curated source and, for a migration, `db/schema.rb`.

`Draft` retains the original plan, history, difficulty and draft ladders for
diagnostics and `plan.notes`. A retry reuses plan/history/difficulty but
**calls `retry_ladders` afresh**, as today, for just the retried kind. It must
not reuse all the draft ladders or mutate `draft.ladders`. The existing user
attribute reads remain reads from the same in-memory user; this extraction
does not add a reload or invent a cross-call profile snapshot.

`JudgedGeneration#resolve_rejections` can retry several kinds concurrently
through `CallerZoneThread`. Each call gets a fresh renderer; `only` and
`fixed_concept` must not be stored on the shared draft, module or service.
Rendering a retry must not change a later full render from the same inputs.

## Retention-block duplication

The main block (lines 1193-1205) and the fourth block (lines 1230-1240) share
one shape: if the list is non-empty, a heredoc with a heading and bullets,
else `""`. The established blocks (lines 1207-1218, 1242-1250) have the same
shape. The texts differ in wording and grammar ("checks"/"check",
"concepts"/"concept", "section(s) it may occupy"/"the fourth section"), and
the main block annotates each concept with the sections that can host it
(`annotate_retention_concept`, which filters through
`ConceptVocabulary.selectable_for_section`) while the fourth block lists
`cm.concept` plainly.

So the prose cannot be shared without changing output, and the annotation
difference is behavior, not copy. Each block becomes a named private method
with an empty-string guard and its verbatim heredoc. Do not introduce a
parameterized prose builder just to hide those guards. These four different
rules share syntax; they are not duplicate domain knowledge.

One gap matters here: direct prompt tests do not supply a non-empty
`fourth_established` list. The characterization spec passes `[]`, and
`ai_service_spec.rb` never passes the keyword. Moving that block incorrectly
could escape these explicit prompt assertions. Step 0 closes the gap before
any code moves.

## Design

### `GenerationPrompt`

A new class at `app/services/generation_prompt.rb`:

```ruby
class GenerationPrompt
  def initialize(user, language, plan:, history:, difficulty:, ladders:, retention_annotation:)
  def render(only: nil, fixed_concept: nil)   # the prompt text
  def schema(only: nil)                      # today's exercise_schema_for
end
```

- `plan` is any object answering the thirteen `DailyPlan::Result` readers the
  table above lists. In production it is the `Result`; in a spec it is a
  `Result` built by a helper, or a `Struct` with the same readers (the way
  `judged_generation_spec.rb` already builds one).
- `history`, `difficulty` and `ladders` have no defaults. The caller supplies
  them. `only:` and `fixed_concept:` keep `nil` defaults, since a first draft
  has neither.
- `retention_annotation` takes `(concept_mastery, kinds, language, mode, rungs)`
  and returns the current annotated string or nil. `AiService` supplies
  `method(:annotate_retention_concept)` without `send`. This is the only
  source-sensitive exception to moving template helpers: the existing
  method is itself provider-facing exercise content through `RealSource`.
  Keep its definition and `can_host?` unchanged and authoritative, not copied
  into the new class. Specs use the real bound method from their existing
  no-network service double, with unpersisted inputs.
- `render` returns the same string `build_exercise_prompt` returns today.
- Both full rendering and `schema` resolve kinds through
  `ExerciseSection.for_plan`, or `[only]` for a retry, in registry order.
  Do not cap or normalize the legacy builder inputs during extraction.
  Invalid slot selections still raise; unknown flavors still use `fetch`.
- The class reads constants from where they live now, qualified:
  `AiService::SCENARIO_POOLS`, `ConceptVocabulary::TYPESCRIPT_FLAVORED_CONCEPTS`,
  `KindDifficulty::LEVELS` and `LEVEL_DEFINITIONS`, `ExerciseSection::MAX_SCAFFOLD_LABELS`
  and `MAX_SCAFFOLD_LABEL_LENGTH`, `UserText::MAX_NAME_LENGTH`, `User::SKILL_LEVELS`,
  `DailyPlan::FOURTH_BUCKETS` is no longer needed (it only served the
  database default). `LADDER_FIELD_FOR` stays with `ladders_for`.
- `config_for` becomes a class method on `AiService` (`AiService.config_for`),
  with the instance method delegating to it the way `error_code_for` already
  does. `GenerationPrompt` and `script/model_comparison.rb` call the class
  method; the other callers in `AiService` keep calling the instance one.
  The lookup and its `AiService::Error` stay in one place, including the
  language-independent buckets used by reference prompts. Keep
  `require_supported_language!` before `DailyPlan.for`, so unsupported
  generation fails before planning, database work or a provider call.

### What moves out of `AiService`

Template composition moves; source-sensitive annotation stays as described
above, and shared difficulty text has two production consumers:

| Today (`ai_service.rb`) | Lines | New home |
|---|---|---|
| `build_exercise_prompt` | 1159-1325 | `GenerationPrompt#render`, split into named private methods (profile, history text, reinforcement text, the four optional blocks, TypeScript line, section guidance) so each is under 25 lines. The heredoc template stays one method |
| `exercise_schema_for` | 1145-1158 | `GenerationPrompt#schema` |
| `annotate_retention_concept`, `can_host?` | 987-1000 | Stay unchanged on `AiService`; the renderer invokes the bound annotation callable |
| `annotate_reinforcement` | 1086-1088 | `GenerationPrompt` (private); no other caller |
| `kind_difficulty_guidance`, `level_difficulty_paragraph`, `unlocked_difficulty_line`, `locked_difficulty_line` | 1489-1528 | `GenerationPrompt::DifficultyGuidance`, in `app/services/generation_prompt/difficulty_guidance.rb` |
| `scaffolded_kinds_clause` | 1530-1532 | `GenerationPrompt` (private) |
| `generation_guidance_for` | 1534-1546 | `GenerationPrompt` (private) |
| `shared_concept_guidance`, `scenario_flavor_guidance` | 1326-1343 | `GenerationPrompt` (private); these are plan-level instructions, not vocabulary groups |
| `data_modeling_idiom_guidance`, `meta_skill_framing_guidance`, `code_smell_naming_guidance`, `oo_design_violation_guidance`, `module_design_depth_guidance`, `silent_correctness_guidance`, `domain_modeling_guidance` | 1345-1467 | Private instance methods in the included `GenerationPrompt::ConceptGuidance` module, in `app/services/generation_prompt/concept_guidance.rb`; same names and text |

What stays on `AiService`: `draft_exercise`, `ladders_for` (it queries
`ConceptReference`; supplying ladders is the caller's job), `retry_ladders`,
`retry_section`, `finish_generation`, every log method,
`eased_concepts_for`, `reduced_concepts`, `build_system_prompt`, and the
constants (`SCENARIO_POOLS`, `LANGUAGE_PROMPTS`, `LADDER_FIELD_FOR`,
`MAX_LADDER_*`), plus the retained annotation methods. Moving constants is
not needed for the goal and would widen the diff into `docs/code-notes`
entries that document them.

`DifficultyGuidance.render(rungs:, difficulty:, ladders:)` is the one public
entry to the existing difficulty block. Both `GenerationPrompt#render` and
`AiService#kind_difficulty_diagnostics` call it; diagnostics measure that
exact string's `.length`, including its leading newline. Keep the paragraph
and lock-line methods private. Do not widen `GenerationPrompt` with public
helpers solely to preserve tests of private implementation details.

This third file earns its place through two real consumers, not a line-count
target. Measure the final files rather than relying on estimates: every new
`app/` file stays under 300 lines and each new or substantially rewritten
method under 25 non-heredoc lines, or the implementation PR explains the
specific exception. No new abstraction is needed for the four optional
blocks. No ladder budget or vocabulary constant changes.

Concept-group assertions move to rendered prompts, including assertions
that each group's instruction occurs once. The private module keeps one
home for the text without exposing seven more public methods. Do not copy
the template's `kind == ExerciseSection::CodeReview` check into the new
renderer. Forward `plan.code_review_mode` uniformly to section guidance:
`ConceptVocabulary.selectable_for_section` already applies it only to code
review, and the other kind implementations ignore it. `DayHosts` and
`ladders_for` already use that uniform forwarding. Pin equivalence across
every language, mode, rung and kind. The existing branch inside the retained
curated annotation method stays untouched; no new shared kind branch is
introduced.

### The callers

`draft_exercise` becomes:

```ruby
prompt = generation_prompt(user, language, plan: plan, history: history,
                           difficulty: difficulty, ladders: ladders)
result = call_and_log(user, purpose: "generate_exercise", read_timeout: ...,
                      system: build_system_prompt(language), prompt: prompt.render)
```

`AiService#generation_prompt` is a private factory that constructs
`GenerationPrompt` with these whole values and
`retention_annotation: method(:annotate_retention_concept)`. Both draft and
retry use it. It owns no selection or rendering policy; its concrete second
use is the script's instance-local prompt override below.

`exercise_prompt_options` is deleted. `Draft` drops `prompt_options`; it
already holds `plan`, `history`, `difficulty` and `ladders`. `retry_section`
builds its prompt from those four draft fields with `ladders:` replaced by
`retry_ladders(...)` and renders with `only: kind, fixed_concept: concept`.
`JudgedGeneration` is untouched: it calls `retry_section` through the
`Provider` callable with the same arguments as today.

`script/forced_concept_drafts.rb` stops sending `:exercise_prompt_options`
and builds its `Draft` without `prompt_options`. Its `send(:ladders_for)` and
`send(:retry_section)` stay; they are outside this refactor's scope and the
script is not under `app/`, where the conventions spec forbids `send`.

The script's service-instance override wraps the new factory, takes the
returned prompt and prepends its extra `domain_modeling_guidance` method to
**that prompt's singleton class**. Ordinary prompts on unmodified services
stay unchanged. Never prepend to `GenerationPrompt` or `ConceptGuidance` globally.
Add a no-network script regression test that renders an ordinary prompt
on a separate service before and after the experiment, runs the experimental render twice without
duplicating its guidance, and checks vocabulary restoration when
`with_concept` exits normally or raises. A live run with a developer's key is
neither necessary nor an acceptable substitute for that test.

### Behavior that must not move

| Seam | Preservation requirement |
|---|---|
| Provider request | Keep `build_system_prompt`, purpose, timeout (including `blocking:`), cache, schema and token options unchanged. Performance history is prompt text, never conversational `history:` on `#call` |
| Planning | No new `DailyPlan.for`, `recent_performance`, difficulty lookup, random roll or clock read inside rendering/retry. Plan notes and diagnostics still describe the original plan |
| Retention | Main annotations use the generated language, current mode, selected kinds and their rungs, not the mastery row's bucket as the language. No host means no main retention block; fourth annotations remain plain concept names |
| Retry | Narrow kinds, schema, hosting and difficulty to `only`; suppress shared-concept advice; keep the fixed-concept line and existing other advisory blocks unchanged, even if broader than the retry. Do not silently clean up that text |
| Ingest | Keep expected keys, fixed concepts, source, pitched-at rungs and eased flags exactly as today. `ProblemSetIngest` remains the validation authority; the renderer never parses or normalizes provider output |
| Finish and errors | Preserve suggested-concept recording, dropped sections, plan notes, logs, failure propagation and usage rows. Preserve answer-key stripping in diagnostics and the judge |
| Profile and history | Keep `UserText.tagged`, blank-name handling, focus fallback, skipped versus unreviewed ratings, absent historical fields and supplied history order. Do not add trial, track, suggestion, guide or book-source state |

### Specs

All builder sends, including the multiline characterization call, become
calls on the public class through one helper in
`spec/support/generation_prompt_helpers.rb`. The helper is included through
RSpec configuration, not as top-level methods/constants:

```ruby
def plan_for(**overrides)
  DailyPlan::Result.new(**PLAN_DEFAULTS, **overrides)
end

def generation_prompt(user, language = "ruby_rails", history: [], difficulty: KindDifficulty.none,
                      ladders: {}, only: nil, fixed_concept: nil, **plan_overrides)
  GenerationPrompt.new(user, language, plan: plan_for(**plan_overrides), history: history,
                       difficulty: difficulty, ladders: ladders,
                       retention_annotation: generation_retention_annotation)
                  .render(only: only, fixed_concept: fixed_concept)
end
```

`generation_retention_annotation` returns the actual bound
`AiService#annotate_retention_concept` method from a no-network test service
(the existing service double or `FakeService`), never a reimplementation.
This preserves the curated helper without making tests reach through
`send` or call a provider. No new service is needed per concept.

`PLAN_DEFAULTS` holds the builder's current pure defaults (`third: :challenge`,
`pattern: :pattern`, `fourth: :plan_review`, `code_review_mode: :application_code`,
`scenario_flavor: :general`, empty lists, `nil` for the rest, including the
three non-prompt fields). These are legacy test conveniences, not production
planning defaults. A call site then changes only its head:
`service.send(:build_exercise_prompt, user, "ruby_rails", third: :x, due_checks: [cm])`
becomes `generation_prompt(user, "ruby_rails", third: :x, due_checks: [cm])`.
The keywords are the same names, so the rewrite is mechanical and reviewable
with a diff. The two retry examples pass `only:` and `fixed_concept:` as now.
The characterization spec's `render` method and the hardening spec's one call
go the same way.

Also migrate these dependencies; a literal `send(:build_exercise_prompt`
search alone does not find them all:

| Target | Calls | After |
|---|---|---|
| five vocabulary-group `*_guidance` methods | 33 | Assertions on `GenerationPrompt#render`, retaining the wording checks and testing each group's single inclusion |
| `exercise_schema_for` | 7 | `GenerationPrompt#schema`, through a second helper `generation_schema(user, language, only: nil, **plan_overrides)` |
| `kind_difficulty_guidance`, `unlocked_difficulty_line`, `locked_difficulty_line` | 6 | `DifficultyGuidance.render`; retain the exhaustive level assignments and lock subsets, including mixed-lock overhead |
| `annotate_retention_concept` | 3 | Stays private on `AiService`; assert its host annotations through the rendered prompt |
| `build_exercise_prompt` expectation / method overrides | 1 / 2 | Capture `prompt:` at the existing fake provider `#call` seam while exercising real `generate_exercise`; preserve assertions about the rolled kind and overdue-check reservation |
| `build_system_prompt`, `ladders_for`, `retry_ladders`, `retry_section` | 11 | unchanged, these stay on `AiService` |

For the budget test, measure lock overhead through the complete public
difficulty renderer with identical rungs and empty ladders, comparing each
lock subset with the all-locked case. Keep the existing assertion that this
delta holds with populated ladders and every level assignment. Do not expose
private lock-line methods, sample fewer day shapes, or raise
`MAX_LADDER_GUIDANCE_CHARS` to make this extraction pass.

Add explicit no-SQL and input-nonmutation checks around renderer construction,
`render` and `schema`, with already-built inputs and a warmed schema cache.
Retain failure assertions for unsupported languages, invalid slots and
unknown flavors. Add an integration assertion that logged
`kind_difficulty_chars` equals the shared renderer's exact length for the
draft's kinds/difficulty/ladders, including after a retry. Existing isolation
and provider-envelope assertions remain unchanged.

The conventions spec still forbids `send` and raw `Thread.new` under `app/`.
No exemption is needed for the retained bound callable. The migration is
complete when references are accounted for, not when a global send count
hits a target.

### Docs

- `docs/code-notes/app/services/generation_prompt.md` and the matching
  `generation_prompt/concept_guidance.md` and `difficulty_guidance.md`
  notes: move relevant entries from `ai_service.md`. Keep notes for the
  retained annotation methods and explain their source-pool constraint.
  Do not copy stale prose: for example, the existing ladder-budget note's
  "a day without explicit targets sends none" no longer matches
  `difficulty-targets-and-locks.md` or the current renderer.
- `docs/file-map.md`: a line for each new file; the `ai_service.rb` line
  stops claiming the generation prompt.
- `.claude/rules/patterns.md` and `.claude/rules/providers.md`: clarify that
  `AiService` still owns provider orchestration and delegates generation
  text to `GenerationPrompt`; the template-method and callable-provider
  patterns remain. The vocabulary-group entry names
  `GenerationPrompt::ConceptGuidance`.
- `.claude/rules/generation.md`: update `meta_skill_framing_guidance`'s home;
  keep `AiService#can_host?` accurate. Add the new generation renderer and
  nested files to the relevant generation/provider rule path globs so the
  rules continue loading when those files are edited.
- `docs/decisions/two-stage-generation.md` and
  `.github/copilot-instructions.md`: the two mentions of
  `build_exercise_prompt` each. The dated
  `docs/proportionality-concept-2026-10-07.md` keeps its name with the new
  one beside it, as #334 did.
- `docs/decisions/meta-skill-concepts.md`, `shared-concept-on-a-real-struggle.md`,
  `code-review-content-modes.md`, `design-comparison-the-second-fixed-section.md`,
  `difficulty-targets-and-locks.md`, `drills.md`,
  `docs/code-notes/app/models/exercise_section/parsons_problem.md` and
  `.github/copilot-instructions.md:101` name `can_host?`, a guidance method
  or `kind_difficulty_guidance`; update moved references and leave retained
  ones accurate. The grep in verification is the authority, not this list.

The class renders an already-made decision; it does not become a second
planner. The architecture preserves one authority per fact and the provider
template method through delegation. State the retained curated helper and
its unchanged existing kind check explicitly in the implementation PR rather
than claiming every template helper moved. No new kind/provider/bucket policy
belongs in this shared renderer.

## Steps

Work sequentially, with independently reviewable commits. Agent
orchestration is not a requirement of this refactor.

0. **Close coverage gaps against unchanged app code.** Keep all existing
   snapshots. Add valid planned shapes from the optional slots and registry,
   including nil `pattern`, `third` and `fourth`, filtered through
   `ExerciseSection::MAX_SECTIONS`; assert exact schema keys and ordering,
   including both fixed kinds. Cover both languages and every code-review
   mode. Use explicit deterministic inputs, not random plans.

   Add focused populated fixtures for non-empty main and fourth established
   lists, hostable/unhostable retention, reduced and drilled reinforcement,
   shared-concept advice, non-empty history (including missing legacy fields
   and skipped answers), both flavors, profile fallbacks, targeted/untargeted
   rungs, and mixed locks with ladders. Separate the fourth reinforcement
   case from its retention case: the planner never supplies both together.
   Do not use an impossible "everything populated" fixture as the only
   evidence for real production behavior.

   Ground Ruby fixtures in both a real method and a migration, and explicitly
   cover the curated `AiService#annotate_retention_concept` entry. JavaScript
   stays source-free. Add retry fixtures for fixed, third and fourth kinds:
   one-section schema/difficulty, the original plan's advisory blocks,
   mode-aware hosting, shared-concept suppression and the fixed concept.
   Use a source whose content is unchanged by this refactor.

   Record only new fixtures with `UPDATE_PROMPT_SNAPSHOTS=1` against
   unmodified app code and inspect the diff to ensure no existing fixture
   changed. Extend the "no snapshot left behind" manifest with the new shapes.
   Commit these tests and fixtures before moving implementation.
1. **Move the code.** Create `GenerationPrompt` and `ConceptGuidance` with
   unchanged text, plus `DifficultyGuidance` for both production consumers.
   Extract named private blocks without changing whitespace. Keep the
   curated annotation method and its helper unchanged. Migrate diagnostics
   to the shared difficulty renderer in this commit, before deleting its
   old method. Forward mode through the existing kind/vocabulary interfaces
   without a new kind branch. Add no-SQL,
   nonmutation and repeated-render checks. Migrate direct helper tests in
   the same commit rather than publishing formerly private methods to keep
   them green. A temporary `build_exercise_prompt` wrapper may preserve its
   old signature/defaults until the callers change; remove it in step 2.
2. **Switch the callers and remaining tests together.** Update
   `draft_exercise`, `retry_section`, `Draft` and the script.
   Migrate every builder send, spy and override and add the script isolation
   and draft/retry contract tests. Delete `exercise_prompt_options` and the
   temporary builder wrapper. Keep the retained annotation callable.
3. **Update docs and rule globs.** Follow the inventory above. Ensure the PR
   description names the source-sensitive exception and three-file split.

Run focused checks while editing; after the final implementation change run
the full unit suite once, then system specs and lint before marking the
implementation ready. Re-run failed checks after fixes rather than repeating
unchanged full suites at every mechanical step.

## Risks

- **A moved block renders differently and no spec notices.** Highest for
  `fourth_established`, real short days and retries. Step 0 records the
  missing cases before any code moves; unchanged legacy snapshots alone
  are insufficient.
- **A code move changes exercise content.** `RealSource` reads executable
  source as data. Preserve the annotation definition and its pool entry,
  id, ordering, instruction and scenario; the all-entry resolvability spec
  alone would not catch an id change that resets source-history selection.
- **Diagnostics fail after billing.** Moving difficulty text without its
  diagnostics caller leaves a missing method on the generation finish path.
  Both paths use `DifficultyGuidance.render`, with exact-length coverage.
- **Interpolation context.** The template reads constants that were
  unqualified inside `AiService` (`SCENARIO_POOLS`, `LANGUAGE_PROMPTS`).
  A missed qualification raises `NameError` on first render, which the
  snapshots catch for the 72 shapes but the step-0 fixtures must cover for
  the optional blocks.
- **`config_for` has a dozen callers on `AiService`.** Promoting it to a class
  method with an instance delegator keeps them; a missed one raises
  `NoMethodError`, caught by any prompt spec for that builder.
- **The script.** Its current service-local prepend must not become global.
  The new no-network regression covers cleanup and a second ordinary
  service; a live paid generation is not part of this verification.
- **Isolation specs.** Both `level_suggestion_isolation_spec` and
  `trial_isolation_spec` glob `app/services/**` for forbidden readers; the
  new files are scanned automatically and read none of the guarded names.
  The byte-identical prompt examples in both specs run the full draft path
  and are a second safety net for step 2.
- **Dead locals.** `Lint/UselessAssignment` is off. After extracting the
  builder's locals into methods, grep the new files for an assigned name
  used nowhere.
- **Doc drift.** Search all current guidance and code notes, including rule
  path globs. A false pointer must be corrected; dated design specs remain
  historical evidence, not active method-location instructions.
- **Scope creep.** The group methods and the difficulty block move
  because the template interpolates them. Nothing else about them changes.
  No wording, no new guidance, no constant moves. The characterization spec
  holds the first; review holds the rest.
- **`Draft` loses a field.** `ai_service_spec.rb:1718` and the script build
  a `Draft` by hand with `prompt_options: {}`; both are updated in step 2.
  `judged_generation_spec.rb` builds its own `draft_type`; verify its
  structural contract still holds. Do not broaden the `Provider` callable
  or change judge orchestration.

## Verification

These are gates for the implementation, not claims that this spec-only PR
has implemented or verified the refactor:

1. `bundle exec rspec spec/services/generation_prompt_characterization_spec.rb`
   after each code move, without snapshot-update variables. Compare tracked
   fixture changes against the step-0 commit with `git diff`, not just
   `git status` (committed rebaselines leave a clean status). Only step 0
   adds prompt snapshots; no existing prompt or request snapshot changes.
2. The full unit suite, `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`,
   once after the implementation settles. Include the renderer, script,
   real-source, provider-request, isolation, generation/job and judge tests.
   This shared-authority change is not verified by a scoped run alone.
3. `bundle exec rspec spec/system` once before the implementation is ready.
4. `bin/rubocop` and `bin/comment-check`, including the three house comment
   cops on the new files (at most five comments per file; the moved code
   notes carry their comments with them).
5. Search `app`, `spec` and `script` for the symbols
   `build_exercise_prompt`, `exercise_prompt_options` and `prompt_options`,
   not just one-line sends: no old definitions, calls, overrides or spies
   remain. Search moved helper names too, accounting for each consumer.
   In `docs`, `.claude` and `.github`, update active references; this dated
   spec and dated design history may describe the old names. An expectation
   that this spec itself contains none is not a usable verification gate.
6. Line counts: `wc -l` on all new app files; inspect new/rewritten methods
   excluding heredoc bodies. Explain any threshold exception in the PR.
7. The `critical-reviewer` agent reviews the branch as a whole against the
   repository, with this spec as its brief, before the PR leaves draft.
8. The PR description states which checks actually ran, any unverified scope,
   unchanged prompt/request snapshots and source identity, the retained
   annotation callable, the shared difficulty renderer, the updated pattern
   entries and the file/method-size outcome. Do not claim no drift from code
   inspection alone or claim deterministic provider output from identical
   requests.

## Evidence for this spec review

Reviewed the root `CLAUDE.md` (the only file with that name in this checkout),
the applicable `.claude/rules/` files, and the linked generation, difficulty,
source and planning decisions. Traced `DailyPlan` and `SectionRotation` into
`draft_exercise`, the template and schema, `retry_ladders`/`retry_section`,
`JudgedGeneration` and finish diagnostics. Also inspected the real-source
registry/resolver, kind and vocabulary interfaces, history reads, the forced
concept script and its test consumers.

Against unchanged app code at `3c96c35`, these scoped checks passed:

- Generation characterization and `ai_service_spec`: 761 examples.
- Real-source, judged-generation, provider-request characterization, and
  level-suggestion/trial isolation specs: 92 examples.
- A test-environment runner confirmed the legacy snapshot shape has five
  kinds, the multiline builder send brings the total to 79 call sites, and
  the curated annotation method resolves as a ten-line excerpt.
- A runner compared current section guidance with uniform mode forwarding
  for all 240 language/mode/rung/kind combinations; every string matched.
  A separate Ruby check confirmed the difference between instance-local
  and shared-module singleton prepends.

This revision changes only the design document. It adds no runtime input,
query, controller action, provider call, JSONB field, view, script behavior,
auth/mail setting or claim operation; those review checks introduce no new
runtime exposure here. The proposed extraction still needs the preservation
gates above, particularly source identity, diagnostics, retry isolation and
the unchanged ingest/answer-key safeguards. No test assertion or fixture was
changed during this review.

The full unit suite, system specs and linters were not run for this
documentation-only revision. No live provider call was made, and the
unimplemented refactor is not certified drift-free by these baseline checks.
