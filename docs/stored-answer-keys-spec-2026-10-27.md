# Spec: store what each discovery section planted (2026-10-27)

Checked against origin/main at `b52423e`. Not built yet: the review stability
baseline (`script/export_review_baseline.rb`, then
`script/regrade_review_baseline.rb`) runs first, so there is a measurement of
today's grader to compare against.

## Why

Four kinds ask the generator to plant something and then throw away what
was planted:

| Kind | What the generator is told to plant | Stored today |
|---|---|---|
| `code_review` | one defect, test smell or migration flaw ("EXACTLY ONE flaw" for a `RealSource` excerpt) | nothing |
| `security_review` | one real, exploitable vulnerability | nothing |
| `plan_review` | 2-3 flaws: a technical anti-pattern, a scope-creep item, an unflagged behavior change | nothing |
| `pseudocode_to_code` | at least one requirement an under-specified plan would miss | nothing |

The grader is then told to grade "the one planted issue" or "each planted
flaw" and has to work out from the snippet or plan what that was. When it
guesses wrong, it grades the answer against a different problem from the one
the generator meant. Nothing records the guess, so a wrong grade of this kind
can't be told apart from an honest miss.

`design_comparison` (`answer_key`) and `ambiguity_hunt`
(`planted_ambiguities`) already store their keys, and the strip sites already
read the field list generically. This spec gives the other four the same
treatment.

## What changes

### 1. The field

Each of the four kinds stores its key under `answer_key`, the field name
`design_comparison` already uses, with a shape of its own. One name keeps
`ExerciseSection.all_answer_key_fields` at two entries and makes "the key"
mean the same field in every kind. Each kind's `.answer_key_fields` returns
`[ "answer_key" ]`.

| Kind | `answer_key` shape |
|---|---|
| `code_review` | `{ "issue": what is wrong and where, quoting the code; "why_it_matters": what goes wrong because of it in this code; "fix": a fix that works as written }` |
| `security_review` | `{ "vulnerability": what it is and where, quoting the code; "exploit": how an attacker uses it here; "mitigation": a change that closes it }` |
| `plan_review` | `{ "flaws": [ { "category": "technical_anti_pattern" \| "scope_creep" \| "unflagged_behavior_change", "flaw": what is wrong, quoting the plan; "pushback": what a reviewer should ask for } ] }`, 2-3 entries |
| `pseudocode_to_code` | `{ "missable_requirements": [ the requirement, and what a plan that misses it gets wrong ] }`, 1-3 entries |

The key quotes code or plan text rather than citing line numbers.
`ProblemSetIngest#format_code!` re-indents code once at ingest, and Prettier
can re-wrap JavaScript lines, so a line number written by the provider can
point at the wrong line by the time anyone reads it.

An alternative is one field name per kind (`planted_issue`,
`planted_vulnerability`, `planted_flaws`, `missable_requirements`), the way
`ambiguity_hunt` names its field. That costs four more entries in the strip
list and gains only a self-describing name. This spec takes `answer_key`.

### 2. The generation schema

Each kind's `.schema_fragment` gains the `answer_key` object above, with
one line in its `.generation_guidance` saying the key is hidden grading
data: never restated, hinted at or echoed in the question, the scenario,
the teaching note or the diagram. `ambiguity_hunt` has that line already;
copy its wording.

The fragment's indentation contract (first line unindented, fields at 4,
closing brace at 2) holds. `retry_section` builds from the same fragments,
so a retried section carries a key too. A `RealSource` `code_review`,
`test_file` and `schema_review` mode all use the one fragment; the key
describes whichever flaw was planted.

Cost: about 60-150 more output tokens per keyed section on the generation
route (Opus 5.5 for Claude), well under a cent a day. The generation call's
output cap is the service's `MAX_TOKENS` (16,000 on Claude), so headroom is
not a concern, but the PR measures one real generation per language to
confirm.

### 3. The ingest boundary

`ProblemSetIngest` is where provider output is validated, so each kind's
`.reject_unusable!` normalizes its key:

- strings stripped, each bounded (say 500 characters, truncated) and blank
  entries dropped
- lists bounded (`plan_review` at 4, `pseudocode_to_code` at 3), an unknown
  `plan_review` category dropped from that entry, not the entry itself
- an unusable key (missing, not an object, or empty after cleaning) is
  removed

**Decision for you: what happens to a section whose key is unusable.**

- **Keep the section, without a key (recommended).** The key only helps
  grading, and the grader falls back to today's behavior for a keyless
  section. Rejecting would spend a retry, or drop the section, over a field
  the engineer never sees. `GenerationDiagnostics` logs
  `answer_key=missing kind=…` (no content) so the miss rate is visible. If
  it turns out high, revisit.
- **Reject, the way `design_comparison` and `ambiguity_hunt` do.** Those two
  can't be graded without their key. These four can, so rejecting trades
  sections for consistency.

### 4. The section judge never sees a key

`SectionJudgePrompt.generate` already removes every
`ExerciseSection.all_answer_key_fields` field and every `SERVER_STAMPS` field
before the judge reads the section. Because the four kinds reuse
`answer_key`, the list doesn't change and the judge's prompt is unchanged for
them. A judge edit touches `.prose_fields` only, and none of the four kinds
lists `answer_key` or the code or plan it describes there, so an edit can't
make the key stale.

Specs:

- `section_judge_prompt_spec`: for each of the four kinds, a section with
  a sentinel in every `answer_key` value renders no sentinel.
- `judged_generation_spec`: an edited section keeps its `answer_key`
  unchanged.

### 5. The other places a key must never reach

The rule (CLAUDE.md): answer-key fields never reach the page, a
pre-submission AI context or a log before review. Every current site either
reads the list or renders from an allowlist:

| Site | How it is kept out | Change needed |
|---|---|---|
| `SectionJudgePrompt` | removes `all_answer_key_fields` | none |
| `GenerationDiagnostics` (`delivered:` log) | `ExerciseSection.without_answer_keys` | none |
| `SectionContext.render` (the duck, the difficulty assessment) | allowlist of fields | none; `section_context_spec` already fills every listed key field with a sentinel |
| `PseudocodePrompt.critique` / `.translate` | take `problem_statement:` only | none; add a spec that a keyed section's critique request carries no key text |
| Every page (dashboard, submitted dashboard, history) | partials render named fields | add each kind's key text to `ANSWER_KEY_MARKERS` in `section_rendering_characterization_spec` |
| `script/compare_models.rb generate` | `without_answer_keys` | none; `model_comparison_spec` loops over the list |
| `JudgeSolve` and `/admin/judge_solves` | only kinds with `judge_solve_options` (`design_comparison`) | none |

`FakeService::EXERCISE_PROBLEM_SET` gains a key for each of the four kinds,
so the specs above exercise real stored keys end to end.

### 6. The grading prompt

Each kind's `.review_context` adds one line when the section has a key,
worded like `design_comparison`'s: "Answer key (hidden from the engineer,
known here for grading): …". With no key, the line is absent and the
section's context is byte-identical to today's.

Each kind's `.grading_note` names the main point by the key when there is
one ("the issue the answer key names") and keeps today's wording when there
isn't. The rubric, the levels and what earns each rating are unchanged.
This spec does not decide how to grade a different real defect than the
planted one. Today's grading notes don't say, and that question belongs to
the route-based review work.

The day context holds every section's `review_context`, including a
skipped section's, so the walkthrough prompt for a skipped section gets the
key too, and "What a good answer covers" can name what was planted rather
than a guess.

**Decision for you: `RUBRIC_VERSION`.** The recommendation is to leave it
unchanged. The scale means the same thing; the grader just stops guessing
what the problem was. Raising it would restart the competency gate's and
level suggestions' evidence over a change that shouldn't move what a rating
means. The stability baseline is how to check that claim (see Measuring).

Snapshots: `review_prompt_spec` gains a keyed day and keeps day A and day B
byte-identical (they have no keys). The generation prompt snapshots under
`spec/fixtures/prompt_snapshots/` change wherever one of the four fragments
renders, and are re-recorded in the same PR, each diff read by hand.

### 7. Only new problems get keys

No backfill. A key written now for an old snippet would be a provider's
guess at what was planted, which is the guess this change removes.
Every reader treats a missing key as today's behavior: the review context
leaves out its line, the grading note uses today's wording, ingest never
sees old rows. A spec pins that an old, keyless row's review prompt is
byte-identical to today's.

## Measuring

The stability baseline is the before picture. After keys ship and about
two weeks of keyed days exist:

1. Export keyed sections with the same script.
2. Regrade each one 5 times with the key, and 5 times with the key removed
   from the section, the only difference between the two runs. That needs one
   option on `script/regrade_review_baseline.rb` (`--without-keys`),
   added in the build PR.
3. Compare, by kind, how often the rating changes between runs and how
   often it moves more than one level, with and without the key.

If the key doesn't make grading more stable, or moves ratings systematically,
say so on the PR before deciding on `RUBRIC_VERSION`.

## Docs and rules

- `.claude/rules/generation.md`: one entry ("Stored answer keys"), naming
  this doc's decision record.
- `docs/decisions/stored-answer-keys.md`: the decision, with the two
  decisions above as you settle them.
- `docs/code-notes/app/models/exercise_section/*.md` for each kind that
  gains a key, where the reasoning needs more than the code says.
- The CLAUDE.md isolation bullet already covers `all_answer_key_fields`, so
  it stays as is.

## Stop conditions

Stop and come back to you, without building further, if:

- a generation snapshot diff changes anything beyond the four fragments and
  their guidance lines
- the measured generation run truncates, or a kind's key comes back
  unusable in more than one of the runs
- any strip site turns out to name a field instead of reading the list
- the keyed grading run in the PR moves a calibration fixture off its
  expected rating (`script/compare_models.rb review_calibration`)
