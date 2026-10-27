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
- **A different finding:** it meets the main point only when it is at least
  as serious as the keyed one in this code; a lesser real finding is
  credited and the keyed point stays an essential gap (section 6).
- **The movement threshold:** systematic rating movement is measured
  against the unkeyed run on the same keyed sections, not the stability
  baseline (Measuring). Decided by the owner on 2026-10-27.
- **Plan review's main point:** the same rule applies to it. A keyed flaw
  meets the main point, and so does a real flaw at least as serious as the
  least serious keyed flaw. Each keyed flaw the answer missed stays an
  essential gap (section 6). Confirmed by the owner on 2026-10-27.
- **Checking keys:** the free quote check at ingest, plus a sampled manual
  read. The owner reads the Ruby `code_review` sections, and a senior
  colleague the owner chooses reads the other three kinds (section 8,
  option B).

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
purpose. The grading note judges a different finding's seriousness against
`why_it_matters`, `exploit` or `pushback` (section 6), and keeping them apart
also leaves room for a later change to show them without the issue
(section 9).

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

The key names the intended point, not the only valid one. A different
finding counts in full only when it is at least as serious as the keyed one
in this code. Each kind's `.grading_note`, when the section has a key, says
so in its own terms, judging seriousness against the key's own
`why_it_matters`, `exploit` or `pushback`, which is why the key carries
them:

- **`code_review`:** "A different issue meets the main point only if, left
  as written, it would do at least as much harm in this code as the answer
  key's why_it_matters describes: a wrong result, lost or corrupted data, or
  a requirement the question states going unmet. A real but lesser issue,
  such as a slower query that still returns the right rows, a naming or
  style problem, or a guard for input this code can't receive, is credited
  in "correct", and the keyed issue stays an essential gap in "missed"." In
  `test_file` mode the harm is a real bug the suite would let through. In
  `schema_review` mode it is data the migration would lose or corrupt, or a
  deploy it would break.
- **`security_review`:** "A different vulnerability meets the main point
  only if an attacker with no more access than the answer key's exploit
  needs could use it to do at least as much: read or change another user's
  data, run code, or gain a role. A real but lesser weakness, such as a
  missing rate limit, a hardening header, an error message that leaks less
  than the keyed vulnerability exposes, or a flaw that needs more access
  than the keyed one, is credited in "correct", and the keyed vulnerability
  stays an essential gap in "missed"."
- **`plan_review`:** "The main point is met by a keyed flaw, or by a real
  flaw in the plan at least as serious as the least serious keyed flaw: one
  that would ship wrong behavior, change behavior nobody asked to change, or
  grow the work past the stated request as much as a keyed flaw does. Each
  keyed flaw the answer missed stays an essential gap. A real flaw the key
  doesn't list is credited in "correct" with no penalty, as an unplanted
  ambiguity is in an ambiguity hunt." This is the same rule as the other
  kinds, applied to the main point. Each keyed flaw stays essential, as each
  planted flaw is today.
- **`pseudocode_to_code`:** "The answer key lists requirements, never an
  approach. A plan that meets a keyed requirement some other way has met
  it. A plan that handles some other real edge case but not a keyed
  requirement is credited for the edge case in "correct", and the keyed
  requirement stays an essential gap." Here the keyed requirements are
  essential pieces rather than the main point, which stays "an approach
  that would solve the problem".

With no key, each note keeps today's wording. The rubric, the levels and
what earns each rating are unchanged.

How a different finding should weigh against the intended one beyond this
rule is left to the route-based review work. Until then, calibration guards
the rule.

**Fixtures.** `code_review_n_plus_one` and `security_review_sql_like` stay
exactly as they are: their expected ratings anchor every earlier
calibration run. Each of the four kinds gets one new keyed fixture in
`spec/fixtures/review_calibration/` instead. A fixture can carry a key: its
`section` goes into the problem set as written, and
`design_comparison_shipping_rates.json` already holds an `answer_key` that
reaches the grader (`model_comparison_spec`, "grades a design comparison's
extra cases from the decoded answer and the key"). Each new fixture holds
the `complete`, `partial` and `miss` answers every fixture needs, since the
calibration run grades all three, and two `extra_answers`. Each extra
answer's only finding is a real flaw the key doesn't name, and each has
its own expected rating:

| Kind | Comparable-severity answer | Expected | Clearly lesser answer | Expected |
|---|---|---|---|---|
| `code_review` | a second real defect in the snippet, as harmful as the keyed one, explained, with a working fix | `solid` | a real but minor issue (a style problem, an unneeded query that still returns the right rows) | `beginner` |
| `security_review` | a second exploitable vulnerability needing no more access, with a mitigation that closes it | `solid` | a hardening gap (a missing rate limit or header) | `beginner` |
| `plan_review` | an unkeyed flaw as serious as the least serious keyed one, with pushback | `developing` (main point met, keyed flaws missed) | a wording or formatting nit in the plan | `beginner` |
| `pseudocode_to_code` | a plan that meets every keyed requirement by a different decomposition | `solid` | a plan that handles a minor unkeyed edge case and misses a keyed requirement | `developing` |

Each snippet or plan is written so that both alternative flaws really
exist in it and the comparable one really is as serious as the keyed one.
Whoever reviews the fixtures checks that before anything is run.

Comparisons with earlier calibration runs use the six original fixtures'
lines, which don't change. The run's totals ("in order", "matched
expected") grow with the new fixtures and stop being comparable with older
totals.

**Keyed versus unkeyed.** `review_calibration` grades each fixture once, as
written. The build adds a `--without-keys` pass, which grades the same
fixtures with the new `answer_key` removed from every section of the four
kinds this spec keys. It keeps `design_comparison`'s `answer_key` and
`ambiguity_hunt`'s `planted_ambiguities`, which today's grader already
reads, so the unkeyed pass grades the way today's grader does.
`ExerciseSection.without_answer_keys` would strip those too, so it is not
the tool here. Each alternative answer is graded both ways.

**Calls and cost**, at the calibration run's measured $0.013 a grade on
Sonnet 5.5 ($0.2613 for 20 grades on 2026-10-09):

| Run | Calls | Cost |
|---|---|---|
| One full calibration run with the new fixtures: 6 original fixtures (20 grades, as today) plus 4 new × 5 answers | 40 | about $0.52 |
| Keyed versus unkeyed: 8 alternative answers × 2 ways × 3 runs | 48 | about $0.63 |
| Total | 88 | about $1.15 |

Both use only a key the owner holds, and the build asks before running
either.

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
whitespace collapsed. It runs after `ProblemSetIngest#format_code!`, so it
sees the code as shown, through a per-kind hook beside `.reject_unusable!`.
That keeps `ProblemSetIngest` free of any branch on kind. Misses travel on
`ProblemSetIngest::Result`, and `GenerationDiagnostics` logs them as
`answer_key_quote=missing kind=…`, next to `answer_key=missing`. A miss
changes nothing. It catches a key that quotes code that isn't there. It
can't catch a key that quotes the right line and misreads it. Prettier can
change quotes and semicolons in JavaScript, so a miss there is a lead to
read, not proof the key is wrong, and the threshold below counts Ruby
sections only. More than 2 misses in the first 10 keyed Ruby sections is a
stop condition: it would mean keys routinely quote code that isn't there.

Options for checking what the quote check can't:

| Option | Cost | Catches | Can't catch |
|---|---|---|---|
| **A. A key-aware check at ingest.** A separate provider call is given the section and its key and asks whether the snippet has the issue the key names and whether the fix works. Its verdict is stored server-side and only logged, or used to drop a bad key; it never feeds the page or any prompt. | One more call per keyed section, about $0.005-0.01 on Sonnet 5.5, so a few cents a day; more time inside the generation deadline. It is also a new pre-submission AI context that sees a key, an exception the isolation rule would have to name. | A key describing a defect the code doesn't have; a fix that doesn't work; a snippet whose worse flaw the key missed. | Mistakes the generator and checker share. A user has one provider key, so in production both calls come from the same provider. |
| **B. A sampled manual check during Measuring.** Keyed sections already reviewed are read from the read-only export, and each gets one call: key right, key wrong, or key right but the code or plan has a worse flaw. The owner reads the Ruby `code_review` sections. A senior colleague the owner chooses reads `security_review`, `plan_review` and `pseudocode_to_code` (and any `code_review` in another language). | Reading time: about 2-3 minutes a section, so roughly an hour for 5 sections per kind, split between two readers. One build: the `--key-sheet` export option below, added in the build PR. | Anything a careful reader sees, including a subtly wrong fix or a misread quote. | Everything outside the sample. It measures how often keys are wrong; it never stops a wrong key from grading. |
| **C. Neither.** Trust the generator: it wrote the snippet and the key in one reply. | None. | Nothing. | Everything. The reason to choose this would be that a key wrong as often as today's grader guesses wrong costs no accuracy. Nobody has measured how often either one is wrong, so there is no case for it yet. |

**Recommendation: B, with the free quote check.** A key is new, and the
first question is how often it is wrong at all. A sample read by a person
answers that and nothing else does: option A puts one model in charge of
checking another from the same provider. If B finds wrong keys often
enough to matter, A is the next step, with its isolation exception decided
then. Not built in this spec beyond the quote check.

The colleague's reading sheet comes from its own read-only production
export, separate from the stability export, and that export runs only
after the owner approves it. It runs in the same `SET TRANSACTION READ
ONLY` transaction as the stability export, and only over sections the owner
has already had reviewed, so no key it carries is for a problem still
waiting on an answer. The build PR adds it as an option on
`script/export_review_baseline.rb` (`--key-sheet`), with a spec that the
output holds none of the fields listed below.

Each entry holds what the reader needs to judge the key against the code:
the kind, the scenario, the question, the full snippet or plan as shown
(`snippet`, plus `current_schema` for a migration; `plan_excerpt`; or
`problem_statement`), and the key. It holds no answer, rating, review,
self-rating or date, so the owner's work stays with the owner. The sheet is
saved outside the repository and deleted once the calls are recorded. Only
the counts of calls go into the build PR.

### 9. Teaching from the key (out of scope)

Out of scope for this PR. Whether the review may show the key's
`why_it_matters` and `fix` (or a vulnerability's `exploit` and `mitigation`,
or a plan flaw's `pushback`) after submission is a separate decision. Today
the rule says a key never reaches the page, before or after review, and
showing these parts would narrow it to "never before review", with
`section_rendering_characterization_spec` changed to match. The place
would be the review block, beside the first-exposure short version, never
the section itself. The short version itself
(`docs/first-exposure-teaching-spec-2026-10-27.md`) shows only
`ConceptReference` fields and doesn't cover keys, so this would be a later
change of its own. Once both are built,
`docs/decisions/stored-answer-keys.md` cites
`docs/decisions/first-exposure-teaching-in-the-review.md` in place of that
spec. Showing a fix would also overlap with `improved_code`, which already
shows a corrected version from a concept's second exposure. The field
shapes in section 1 keep the issue apart from its explanation and fix, so
such a change could show the latter two without revealing more than it
needs.

## Measuring

Stability is not correctness. A grader can give the same wrong rating five
times running. The stability runs show whether a key makes grading more
consistent; the validity check (section 8, option B) shows whether the keys
are right. Both are needed before the `RUBRIC_VERSION` decision stands.

The stability baseline is the before picture. After keys ship and about
two weeks of keyed days exist:

1. Export keyed sections with the same script.
2. Regrade each one 5 times with the key, and 5 times with the new
   `answer_key` removed from every section of the four keyed kinds in that
   day, since the day context shows every section's key, not only the graded
   one's. The `design_comparison` and `ambiguity_hunt` keys stay, as in the
   calibration pass. That is the only difference between the two runs. It
   needs one option on `script/regrade_review_baseline.rb`
   (`--without-keys`), added in the build PR.
3. Compare, by kind, how many sections change rating between runs and how
   many move more than one level, with and without the key, and how many
   sections' typical rating differs between the two and in which direction.
4. Run the sampled manual check (section 8, option B) on the same export:
   the owner reads the Ruby `code_review` sections, and the chosen senior
   colleague reads the other three kinds from the key sheet (section 8),
   which comes from its own approved, read-only export.

**Sample size.** About 14 sections per kind is what two weeks gives
`code_review`, which every day carries, if a set is done every day. The
others are rotating kinds and come up less often. `security_review` shares
the third slot with three other kinds, and `plan_review` and
`pseudocode_to_code` share the fourth slot with `ambiguity_hunt` on days
long enough to have one. Expect roughly 3-5 of each in two weeks. For those
kinds, either keep measuring until each has about 10, or read the result as
a direction, not a figure. The export takes up to 10 of each kind
(`ReviewBaselineExport::PER_KIND`), so waiting adds rows without changing
the script.

**Reporting.** Results are counts ("3 of 14 sections changed rating between
runs"), never percentages. With samples this small a percentage claims a
precision the data doesn't have. `ReviewStability` prints counts only, and
reports drift from the stored rating apart from stability, split by the
stored review's provider. Drift moves with every model and prompt change
since the stored review, so it is never read as stability.

**What counts as systematic rating movement.** For a kind, at least 3
sections whose typical rating differs between keyed and unkeyed grading,
all in the same direction, and more than the run-to-run change the unkeyed
run (step 2) shows on those same sections. The comparison uses the unkeyed
arm, not the stability baseline, because it covers the same sections, model
and day, with only the key different. The baseline is an older sample of
unkeyed sections, with only a few rows of each rotating kind. It stays a
general measure of today's grader, not this threshold's reference. If that happens, say so on the build PR and reopen the
`RUBRIC_VERSION` decision.

**Handling production data.**

- Every production export is read-only (the export runs in a
  `SET TRANSACTION READ ONLY` transaction) and runs only with the owner's
  approval of that export.
- Every export is saved outside the repository and deleted after use.
- The key sheet (section 8) is its own export with its own approval;
  approving the stability export doesn't cover it.
- Any real generation run for measuring token cost uses only keys the owner
  holds, and is asked about before it runs.

## Docs and rules

- `.claude/rules/generation.md`: one entry ("Stored answer keys"), naming
  this doc's decision record.
- `docs/decisions/stored-answer-keys.md`: the decision, including both
  decisions above. It states that `RUBRIC_VERSION` stays unchanged only while
  Measuring shows no systematic rating movement, and what counts as one.
  Where it mentions teaching from the key, it cites
  `docs/decisions/first-exposure-teaching-in-the-review.md` once that exists,
  and this spec's section 9 until then.
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
- for any kind, the keyed grader rates the comparable-severity answer lower
  than the unkeyed grader does, by typical rating over the three runs. That
  would mean the key is being treated as the only valid answer. This
  applies to the comparable-severity answers only; a lesser-flaw answer is
  meant to rate lower once the grader knows the key.
- for any kind, the keyed grader rates the lesser-flaw answer as meeting
  the keyed point, by typical rating over the three runs: `developing` or
  higher for `code_review`, `security_review` and `plan_review`, where it
  would mean the main point was met, and `solid` or higher for
  `pseudocode_to_code`, where the keyed requirement is an essential piece
  and `solid` would mean nothing essential was missed. That would mean the
  severity rule isn't holding.
- the quote check logs a miss on more than 2 of the first 10 keyed Ruby
  sections, which would mean keys routinely quote code that isn't there
