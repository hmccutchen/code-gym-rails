# Spec: store what each discovery section planted (2026-10-27)

Checked against origin/main at `6ecfced`. Not built yet: the review stability
baseline (`script/export_review_baseline.rb`, then
`script/regrade_review_baseline.rb`) runs first, so there is a measurement of
today's grader to compare against.

## Decisions

- **An unusable key:** the section is kept, without a key (section 3).
- **`RUBRIC_VERSION`:** unchanged (section 6). This holds only if Measuring
  shows no systematic rating movement between keyed and unkeyed grading. If
  it does, the decision is reopened before keys feed any evidence reader.

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

The shapes separate what is wrong from why it matters and how to fix it on
purpose, so the first-exposure teaching spec can later show the second and
third parts without the first (section 9).

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
not a concern. Confirming the token count needs one real generation per
language. That run uses only a key the owner holds, and the build asks the
owner before making it.

### 3. The ingest boundary

`ProblemSetIngest` is where provider output is validated, so each kind's
`.reject_unusable!` normalizes its key:

- strings stripped, each bounded (say 500 characters, truncated) and blank
  entries dropped
- lists bounded (`plan_review` at 4, `pseudocode_to_code` at 3), an unknown
  `plan_review` category dropped from that entry, not the entry itself
- an unusable key (missing, not an object, or empty after cleaning) is
  removed, and the section is kept

The section stays because the key only helps grading, and the grader falls
back to today's behavior for a keyless section. Rejecting would spend a
retry, or drop the section, over a field the engineer never sees.
`GenerationDiagnostics` logs `answer_key=missing kind=…` (no content) so the
miss rate is visible. If it turns out high, revisit.

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

The day context holds every section's `review_context`, including a
skipped section's, so the walkthrough prompt for a skipped section gets the
key too, and "What a good answer covers" can name what was planted rather
than a guess.

`RUBRIC_VERSION` stays unchanged (see Decisions). The scale means the same
thing; the grader stops guessing what the problem was. Raising it would
restart the competency gate's and level suggestions' evidence over a change
that shouldn't move what a rating means, and Measuring checks that it
doesn't.

#### When an answer finds something real that isn't in the key

The key names the intended point, not the only valid one. Each kind's
`.grading_note`, when the section has a key, says so in its own terms:

- **`code_review` and `security_review`:** an answer that finds a different
  real defect or exploitable vulnerability in this code, explains why it is
  a problem here and gives a fix that works, has met the main point. "missed"
  names the keyed issue, but not as an essential gap. Without this, a keyed
  grader would mark down an answer today's grader accepts. Today's grader,
  guessing what was planted, tends to take the defect the answer found as
  the planted one.
- **`plan_review`:** a real flaw the key doesn't list is credited in
  "correct" with no penalty, as `ambiguity_hunt` already does for an
  unplanted ambiguity. Each keyed flaw the answer missed stays an essential
  gap, as each planted flaw is today.
- **`pseudocode_to_code`:** the key lists requirements, never an approach.
  A plan that meets a requirement some other way has met it.

With no key, each note keeps today's wording. The rubric, the levels and
what earns each rating are unchanged.

How a different finding should weigh against the intended one in the rating,
beyond this default, is left to the route-based review work. Until then,
calibration guards the default:

- **Fixtures.** Each of the four kinds gets at least two keyed calibration
  answers that find a different real flaw from the one the key names, each
  with its own expected rating. `spec/fixtures/review_calibration/` can carry
  a key: a fixture's `section` goes into the problem set as written, and
  `design_comparison_shipping_rates.json` already holds an `answer_key` that
  reaches the grader (`model_comparison_spec`, "grades a design comparison's
  extra cases from the decoded answer and the key"). `code_review_n_plus_one`
  and `security_review_sql_like` gain a key and two `extra_answers` each. Their
  snippets may need a second real flaw added, kept clearly secondary to the
  planted one, so a different finding exists to be found. `plan_review` and
  `pseudocode_to_code` have no fixture today, so each gets a new one with
  `complete`, `partial` and `miss` answers (the calibration run grades all
  three for every fixture) and the two extra answers.
- **The keyed versus unkeyed comparison.** `review_calibration` grades each
  fixture once, as written. The build adds a `--without-keys` pass, which
  grades the same fixtures through `ExerciseSection.without_answer_keys`,
  so each alternative-finding answer is graded both ways, three times each
  (8 answers × 2 × 3 = 48 calls, about $0.60 on Sonnet 5.5 at the
  calibration run's measured cost per grade). It uses only a key the owner
  holds, and the build asks before running it.

### 7. Only new problems get keys

No backfill. A key written now for an old snippet would be a provider's
guess at what was planted, which is the guess this change removes.
Every reader treats a missing key as today's behavior: the review context
leaves out its line, the grading note uses today's wording, ingest never
sees old rows. A spec pins that an old, keyless row's review prompt is
byte-identical to today's.

### 8. Whether a key matches its section

A wrong key is worse than a guess. The grader is told the key is known
here for grading, so it trusts it: an answer that correctly finds the real
defect gets graded against an issue the snippet doesn't have. The section
judge never sees the key, so nothing in generation checks one.

One check costs nothing and runs whichever option below is chosen. At
ingest, each quote in the key (the code in `issue` or `vulnerability`, the
plan text in `flaw`) is looked for in the formatted snippet or plan, with
whitespace collapsed. A miss logs `answer_key_quote=missing kind=…` and
changes nothing. It catches a key that quotes code that isn't there. It
can't catch a key that quotes the right line and misreads it. Prettier can
change quotes and semicolons in JavaScript, so a miss there is a lead to
read, not proof the key is wrong.

Options for checking what the quote check can't:

| Option | Cost | Catches | Can't catch |
|---|---|---|---|
| **A. A key-aware check at ingest.** A separate provider call is given the section and its key and asks whether the snippet has the issue the key names and whether the fix works. Its verdict is stored server-side and only logged, or used to drop a bad key; it never feeds the page or any prompt. | One more call per keyed section, about $0.005-0.01 on Sonnet 5.5, so a few cents a day; more time inside the generation deadline. It is also a new pre-submission AI context that sees a key, an exception the isolation rule would have to name. | A key describing a defect the code doesn't have; a fix that doesn't work; a snippet whose worse flaw the key missed. | Mistakes the generator and checker share. A user has one provider key, so in production both calls come from the same provider. |
| **B. A sampled manual check during Measuring.** The owner, or a senior colleague the owner chooses, reads keyed sections already reviewed, from the read-only export, and records for each: key right, key wrong, or key right but the snippet has a worse flaw. | Reading time: about 2-3 minutes a section, so roughly an hour for 5 sections per kind. No build beyond the export, which exists. | Anything a careful reader sees, including a subtly wrong fix or a misread quote. | Everything outside the sample. It measures how often keys are wrong; it never stops a wrong key from grading. |
| **C. Neither.** Trust the generator: it wrote the snippet and the key in one reply. | None. | Nothing. | Everything. The reason to choose this would be that a key wrong as often as today's grader guesses wrong costs no accuracy. Nobody has measured how often either one is wrong, so there is no case for it yet. |

**Recommendation: B, with the free quote check.** A key is new, and the
first question is how often it is wrong at all. A sample read by a person
answers that and nothing else does: option A puts one model in charge of
checking another from the same provider. If B finds wrong keys often
enough to matter, A is the next step, with its isolation exception decided
then. Not built in this spec beyond the quote check.

### 9. Teaching from the key (out of scope)

Out of scope for this PR. Whether the review may show the key's
`why_it_matters` and `fix` (or a vulnerability's `exploit` and `mitigation`,
or a plan flaw's `pushback`) after submission is a separate decision. Today
the rule says a key never reaches the page, before or after review, and
showing these parts would narrow it to "never before review", with
`section_rendering_characterization_spec` changed to match. The place
would be the review block, beside or inside the first-exposure short
version (`docs/first-exposure-teaching-spec-2026-10-27.md`), never the
section itself. It would also overlap with `improved_code`, which already
shows a corrected version from a concept's second exposure. The field
shapes in section 1 keep the issue apart from its explanation and fix so
that spec can use the latter two without revealing more than it needs.

## Measuring

Stability is not correctness. A grader can give the same wrong rating five
times running. The stability runs show whether a key makes grading more
consistent; the validity check (section 8, option B) shows whether the keys
are right. Both are needed before the `RUBRIC_VERSION` decision stands.

The stability baseline is the before picture. After keys ship and about
two weeks of keyed days exist:

1. Export keyed sections with the same script.
2. Regrade each one 5 times with the key, and 5 times with the key removed
   from the section, the only difference between the two runs. That needs one
   option on `script/regrade_review_baseline.rb` (`--without-keys`),
   added in the build PR.
3. Compare, by kind, how many sections change rating between runs and how
   many move more than one level, with and without the key, and how many
   sections' typical rating differs between the two and in which direction.
4. Run the sampled manual check (section 8, option B) on the same export.

**Sample size.** About 14 sections per kind is what two weeks gives
`code_review`, which every day carries, if a set is done every day. The
others are rotating kinds and come up less often. `security_review` shares
the third slot with three other kinds, and `plan_review` and
`pseudocode_to_code` share the fourth slot with `ambiguity_hunt` on days
long enough to have one. Expect roughly 3-5 of each in two weeks. For those
kinds, either keep measuring until each has about 10, or read the result as
a direction, not a figure.

**Reporting.** Results are counts ("3 of 14 sections changed rating between
runs"), never percentages. With samples this small a percentage claims a
precision the data doesn't have. `ReviewStability` prints counts only.

**What counts as systematic rating movement.** For a kind, at least 3
sections whose typical rating differs between keyed and unkeyed grading,
all in the same direction, and more than the run-to-run change the baseline
shows for that kind. If that happens, say so on the build PR and reopen the
`RUBRIC_VERSION` decision.

**Handling production data.**

- Every production export is read-only (the export runs in a
  `SET TRANSACTION READ ONLY` transaction) and runs only with the owner's
  approval of that export.
- Every export is saved outside the repository and deleted after use.
- Any real generation run for measuring token cost uses only keys the owner
  holds, and is asked about before it runs.

## Docs and rules

- `.claude/rules/generation.md`: one entry ("Stored answer keys"), naming
  this doc's decision record.
- `docs/decisions/stored-answer-keys.md`: the decision, including both
  decisions above. It states that `RUBRIC_VERSION` stays unchanged only while
  Measuring shows no systematic rating movement, and what counts as one.
- `docs/code-notes/app/models/exercise_section/*.md` for each kind that
  gains a key, where the reasoning needs more than the code says.
- The CLAUDE.md isolation bullet already covers `all_answer_key_fields`, so
  it stays as is. Option A in section 8 would change that, and isn't chosen.

## Stop conditions

Stop and come back to the owner, without building further, if:

- a generation snapshot diff changes anything beyond the four fragments and
  their guidance lines
- the measured generation run truncates, or a kind's key comes back
  unusable in more than one of the runs
- any strip site turns out to name a field instead of reading the list
- the keyed grading run in the PR moves a calibration fixture off its
  expected rating (`script/compare_models.rb review_calibration`)
- the keyed grader rates the alternative-finding calibration answers lower
  than the unkeyed grader does, for any kind, by typical rating over the
  three runs. That would mean the key is being treated as the only valid
  answer.
- the quote check logs a miss on more than a few Ruby sections in the first
  week, which would mean keys quote code that isn't there
