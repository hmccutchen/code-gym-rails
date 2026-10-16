# Build the generation prompt from the plan as a whole

Status: draft for review. Nothing is implemented.
Date: 2026-10-16. Checked against `origin/main` at `3c96c35`.

## Goal

The generation prompt is built by `AiService#build_exercise_prompt` from
eighteen keywords. The plan's result reaches those keywords by being copied
field by field into a hash and then splatted. A new plan field means editing
three places, the builder's defaults query the database, and specs reach the
builder through `send`.

After this change the prompt is built by a public class, `GenerationPrompt`,
from the plan and the other drafted inputs as whole values. No default
queries the database. The prompt can be built from a plain `DailyPlan::Result`
with no rows and no `send`. Every existing prompt snapshot stays identical
byte for byte.

This is a pure refactor. No prompt text, no ordering and no whitespace
changes. Refactor B (one request value per provider call) is a separate PR
with its own spec after this one merges.

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
| ~77 `send` calls reach the builder from specs | 77 in `spec/services/ai_service_spec.rb` and 1 in `spec/requests/security_audit/hardening_targets_spec.rb`: 78 in all. `script/forced_concept_drafts.rb` also sends `:exercise_prompt_options` and `:ladders_for`. Specs send a further 48 calls to helpers the builder interpolates (see "Specs") |
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
| `coverage` | no | | logging only |
| `waiting_checks` | no | | logging only |
| `size` | no | | logging only |

Three values are not plan fields but travel through the same hash:

| Value | Source in `draft_exercise` | Builder keyword |
|---|---|---|
| `history` | `user.recent_performance` (one query) | `history:` |
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
of them matches a real path: `DailyPlan.for` always sets every field.

The builder also reads `user.name`, `user.skill_level` and
`user.focus_areas`. Those are attributes of an object the caller holds, not
queries, and an unpersisted `User.new` serves them (the characterization
spec does this). They stay.

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
difference is behavior, not copy. What can be removed is the four-times
`if list.any? ... else "" end` scaffolding, and the four blocks can each
become a named private method. The heredocs stay verbatim. The spec calls
this a partial answer on purpose: the duplication the review saw is
structural, and the structure is what moves.

One gap matters here: no spec anywhere renders `fourth_established` with a
non-empty list. The characterization spec passes `[]`, and
`ai_service_spec.rb` never passes the keyword. A mistake moving that block
would pass the whole suite today. Step 0 below closes the gap before any code
moves.

## Design

### `GenerationPrompt`

A new class at `app/services/generation_prompt.rb`:

```ruby
class GenerationPrompt
  def initialize(user, language, plan:, history:, difficulty:, ladders:)
  def render(only: nil, fixed_concept: nil)   # the prompt text
  def schema(only: nil)                        # today's exercise_schema_for
end
```

- `plan` is any object answering the thirteen `DailyPlan::Result` readers the
  table above lists. In production it is the `Result`; in a spec it is a
  `Result` built by a helper, or a `Struct` with the same readers (the way
  `judged_generation_spec.rb` already builds one).
- `history`, `difficulty` and `ladders` have no defaults. The caller supplies
  them. `only:` and `fixed_concept:` keep `nil` defaults, since a first draft
  has neither.
- `render` returns the same string `build_exercise_prompt` returns today.
- The class reads constants from where they live now, qualified:
  `AiService::SCENARIO_POOLS`, `ConceptVocabulary::TYPESCRIPT_FLAVORED_CONCEPTS`,
  `KindDifficulty::LEVELS` and `LEVEL_DEFINITIONS`, `ExerciseSection::MAX_SCAFFOLD_LABELS`
  and `MAX_SCAFFOLD_LABEL_LENGTH`, `UserText::MAX_NAME_LENGTH`, `User::SKILL_LEVELS`,
  `DailyPlan::FOURTH_BUCKETS` is no longer needed (it only served the
  database default). `LADDER_FIELD_FOR` stays with `ladders_for`.
- `config_for` becomes a class method on `AiService` (`AiService.config_for`),
  with the instance method delegating to it the way `error_code_for` already
  does. `GenerationPrompt` and `script/model_comparison.rb` call the class
  method; the other callers in `AiService` keep calling the instance one. The lookup and its error stay in one place.

### What moves out of `AiService`

Everything the template interpolates and nothing else:

| Today (`ai_service.rb`) | Lines | New home |
|---|---|---|
| `build_exercise_prompt` | 1159-1325 | `GenerationPrompt#render`, split into named private methods (profile, history text, reinforcement text, the four optional blocks, TypeScript line, section guidance) so each is under 25 lines. The heredoc template stays one method |
| `exercise_schema_for` | 1145-1158 | `GenerationPrompt#schema` |
| `annotate_retention_concept`, `can_host?` | 987-1000 | `GenerationPrompt` (private); `can_host?` has no other caller |
| `annotate_reinforcement` | 1086-1088 | `GenerationPrompt` (private); no other caller |
| `kind_difficulty_guidance`, `level_difficulty_paragraph`, `unlocked_difficulty_line`, `locked_difficulty_line`, `scaffolded_kinds_clause` | 1489-1532 | `GenerationPrompt` |
| `generation_guidance_for` | 1534-1546 | `GenerationPrompt` (private) |
| `shared_concept_guidance`, `scenario_flavor_guidance`, `data_modeling_idiom_guidance`, `meta_skill_framing_guidance`, `code_smell_naming_guidance`, `oo_design_violation_guidance`, `module_design_depth_guidance`, `silent_correctness_guidance`, `domain_modeling_guidance` | 1326-1467 | `GenerationPrompt::ConceptGuidance`, a module of module functions, in `app/services/generation_prompt/concept_guidance.rb`. Same method names |

What stays on `AiService`: `draft_exercise`, `ladders_for` (it queries
`ConceptReference`; supplying ladders is the caller's job), `retry_ladders`,
`retry_section`, `finish_generation`, every log method,
`eased_concepts_for`, `reduced_concepts`, `build_system_prompt`, and the
constants (`SCENARIO_POOLS`, `LANGUAGE_PROMPTS`, `LADDER_FIELD_FOR`,
`MAX_LADDER_*`). Moving constants is not needed for the goal and would widen
the diff into `docs/code-notes` entries that document them.

Line budget: the moved code is about 420 lines. CLAUDE.md asks new `app/`
files to stay under 300 or say why. The two-file split above puts the
template, blocks, schema and difficulty block in `generation_prompt.rb`
(about 260 lines) and the nine concept-group lines in `concept_guidance.rb`
(about 150). If the first lands over 300 after extraction, the PR says so
rather than splitting a third time.

The nine group methods are interpolated by the template and asserted on by
33 spec examples. Making them module functions means specs call
`GenerationPrompt::ConceptGuidance.domain_modeling_guidance` directly, and
`script/forced_concept_drafts.rb`, which today prepends an override of
`domain_modeling_guidance` onto the service's singleton class, prepends onto
`ConceptGuidance.singleton_class` instead. `.claude/rules/patterns.md`'s
"one prompt line per vocabulary group" entry names
`AiService#<group>_guidance`; it changes to name the module.

### The callers

`draft_exercise` becomes:

```ruby
prompt = GenerationPrompt.new(user, language, plan: plan, history: history,
                              difficulty: difficulty, ladders: ladders)
result = call_and_log(user, purpose: "generate_exercise", read_timeout: ...,
                      system: build_system_prompt(language), prompt: prompt.render)
```

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

### Specs

The 78 `send(:build_exercise_prompt, user, lang, **kwargs)` calls become
calls on the public class through one helper in a new
`spec/support/generation_prompt_helpers.rb`:

```ruby
def plan_for(**overrides)
  DailyPlan::Result.new(**PLAN_DEFAULTS, **overrides)
end

def generation_prompt(user, language = "ruby_rails", history: [], difficulty: KindDifficulty.none,
                      ladders: {}, only: nil, fixed_concept: nil, **plan_overrides)
  GenerationPrompt.new(user, language, plan: plan_for(**plan_overrides), history: history,
                       difficulty: difficulty, ladders: ladders).render(only: only, fixed_concept: fixed_concept)
end
```

`PLAN_DEFAULTS` holds the builder's current pure defaults (`third: :challenge`,
`pattern: :pattern`, `fourth: :plan_review`, `code_review_mode: :application_code`,
`scenario_flavor: :general`, empty lists, `nil` for the rest, including the
three logging-only fields). A call site then changes only its head:
`service.send(:build_exercise_prompt, user, "ruby_rails", third: :x, due_checks: [cm])`
becomes `generation_prompt(user, "ruby_rails", third: :x, due_checks: [cm])`.
The keywords are the same names, so the rewrite is mechanical and reviewable
with a diff. The two retry examples pass `only:` and `fixed_concept:` as now.
The characterization spec's `render` method and the hardening spec's one call
go the same way.

The 48 other `send` calls into the moved helpers, and 11 that stay:

| Target | Calls | After |
|---|---|---|
| five of the nine `*_guidance` group methods | 33 | `GenerationPrompt::ConceptGuidance.<name>` |
| `exercise_schema_for` | 7 | `GenerationPrompt#schema`, through a second helper `generation_schema(user, language, only: nil, **plan_overrides)` |
| `kind_difficulty_guidance`, `unlocked_difficulty_line` | 5 | public on `GenerationPrompt` (the `MAX_LADDER_GUIDANCE_CHARS` spec builds shapes and needs the arguments form) |
| `annotate_retention_concept` | 3 | stays private; the three examples assert on the rendered prompt instead |
| `build_system_prompt`, `ladders_for`, `retry_ladders`, `retry_section` | 11 | unchanged, these stay on `AiService` |

The `send` count in `spec/` drops from 399 to about 270. The conventions
spec already forbids `send` under `app/`; nothing new is needed there.

### Docs

- `docs/code-notes/app/services/generation_prompt.md` (new): the entries for
  the moved methods, taken from `ai_service.md`, which loses them.
- `docs/file-map.md`: a line for each new file; the `ai_service.rb` line
  stops claiming the generation prompt.
- `.claude/rules/patterns.md`: the "one prompt line per vocabulary group"
  entry names `GenerationPrompt::ConceptGuidance`.
- `.claude/rules/generation.md`: `AiService#meta_skill_framing_guidance` and
  `AiService#can_host?` renamed to their new homes.
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
  or `kind_difficulty_guidance`; each gets the new home's prefix. The grep
  in verification is the authority, not this list.

No `.claude/rules/patterns.md` pattern is deviated from. The new class is a
pure decision object in the sense that file uses: given the plan and the
drafted inputs it returns text and touches no row.

## Steps

The work runs as a foreman with worker agents, one step each, every step
green before the next.

0. **Close the snapshot gap, on main's code.** Add to the characterization
   spec one "fully populated" snapshot per language: every optional block
   on (`due_checks`, `established`, `fourth_due_checks`,
   `fourth_established` from unpersisted `ConceptMastery.new`),
   reinforcement with a `reduced` and a `drilled` entry, `shared_concept`,
   a `code_review_source` from `RealSource::APPLICATION_CODE` (a constant,
   not a row), a `KindDifficulty` with one locked kind and one target, a
   ladders hash, and a non-empty `history`. Add one retry snapshot
   (`only:` and `fixed_concept:`). Record them with
   `UPDATE_PROMPT_SNAPSHOTS=1` against unmodified code. The spec's
   "no snapshot left behind" example lists the expected files from the
   shapes, so the new fixtures join that list. Commit this first so the
   recorded fixtures are provably from `main`.
1. **Move the code.** Create `GenerationPrompt` and `ConceptGuidance` with
   the method bodies moved verbatim, then extract the builder's local
   variables into named private methods. Every moved method a spec still
   sends to (`build_exercise_prompt`, `exercise_schema_for`,
   `kind_difficulty_guidance`, `unlocked_difficulty_line`,
   `annotate_retention_concept` and the five group methods) keeps a one-line
   private delegator on `AiService` for this step only, so every send still
   passes. Run the characterization spec and `ai_service_spec.rb`.
2. **Switch the callers.** `draft_exercise`, `retry_section`, `Draft`, the
   script. Delete `exercise_prompt_options`. Run the full unit suite.
3. **Migrate the specs.** Add the helper file, rewrite the 78 calls and the
   48 helper sends, delete the delegators from step 1. Run the full unit
   suite.
4. **Docs.** The list above. Run RuboCop and `bin/comment-check`.

Each step is its own commit so a reviewer can read the move apart from the
rewrite.

## Risks

- **A moved block renders differently and no spec notices.** Highest for
  `fourth_established` (no non-empty coverage today) and the retry render
  (two examples). Step 0 is the mitigation; it runs before any code moves.
- **Interpolation context.** The template reads constants that were
  unqualified inside `AiService` (`SCENARIO_POOLS`, `LANGUAGE_PROMPTS`).
  A missed qualification raises `NameError` on first render, which the
  snapshots catch for the 72 shapes but the step-0 fixtures must cover for
  the optional blocks.
- **`config_for` has a dozen callers on `AiService`.** Promoting it to a class
  method with an instance delegator keeps them; a missed one raises
  `NoMethodError`, caught by any prompt spec for that builder.
- **The script.** `script/forced_concept_drafts.rb` has no spec. Its prepend
  target changes. Run it once by hand against the development database as
  part of verification, or accept that it is checked by reading.
- **Isolation specs.** Both `level_suggestion_isolation_spec` and
  `trial_isolation_spec` glob `app/services/**` for forbidden readers; the
  new files are scanned automatically and read none of the guarded names.
  The byte-identical prompt examples in both specs run the full draft path
  and are a second safety net for step 2.
- **Dead locals.** `Lint/UselessAssignment` is off. After extracting the
  builder's locals into methods, grep the new files for an assigned name
  used nowhere.
- **Doc drift.** Twelve docs name a moved method, plus `patterns.md` and `file-map.md`. A missed one is a false
  pointer, not a failure; the grep in verification lists them.
- **Scope creep.** The nine group methods and the difficulty block move
  because the template interpolates them. Nothing else about them changes.
  No wording, no new guidance, no constant moves. The characterization spec
  holds the first; review holds the rest.
- **`Draft` loses a field.** `ai_service_spec.rb:1718` and the script build
  a `Draft` by hand with `prompt_options: {}`; both are updated in step 2.
  `judged_generation_spec.rb` builds its own `draft_type` and is unaffected.

## Verification

Before the PR is marked ready, in this order:

1. `bundle exec rspec spec/services/generation_prompt_characterization_spec.rb`
   after every step. `git status spec/fixtures/prompt_snapshots` shows no
   modified file after step 0; only step 0 adds files.
2. The full unit suite, `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`,
   after steps 2 and 3. `AiService` and `DailyPlan` are shared authorities,
   so a scoped run does not count.
3. `bundle exec rspec spec/system` once before opening the PR.
4. `bin/rubocop` and `bin/comment-check`, including the three house comment
   cops on the new files (at most five comments per file; the moved code
   notes carry their comments with them).
5. `grep -rn "send(:build_exercise_prompt\|send(:exercise_prompt_options\|prompt_options" app spec script`
   returns nothing. `grep -rln "build_exercise_prompt\|exercise_prompt_options" docs .claude .github`
   returns only the dated proportionality doc.
6. Line counts: `wc -l` on the two new files, with the 300-line rule either
   met or explained in the PR description.
7. The `critical-reviewer` agent reviews the branch as a whole against the
   repository, with this spec as its brief, before the PR leaves draft.
8. The PR description states: pure refactor, snapshots unchanged, the
   `patterns.md` entry that was renamed, and the file-size outcome.
