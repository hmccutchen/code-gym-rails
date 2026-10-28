# Implementation plan: stored answer keys

This plan builds `docs/stored-answer-keys-spec-2026-10-27.md` in two PRs from
`main`. Within each PR, work the steps in order. Each step is a commit that
brings its own specs, written first, so the branch stays green throughout.

**Why two PRs.** The spec's recommended check on whether keys are right is a
sampled read by people (section 8, option B). That read can only happen
once keys exist on real sections.
- **PR 1** stores keys but gives them to nothing: not the grader, not the
  page, not any prompt. Keys pile up on real days while grading stays
  exactly as it is today.
- **Between the PRs,** the owner and a colleague read a sample.
- **PR 2** lets the grader read `code_review`'s keys, only if that read says
  they are right often enough. It turns kinds on one at a time and starts
  with `code_review` alone (owner's decision, 2026-10-28), so it doesn't
  wait on the three rarer kinds.
- **Later PRs** turn on `security_review`, `plan_review` and
  `pseudocode_to_code`, one kind each, once that kind's drafts have been
  read (see "Later PRs: the drafted kinds join").

A wrong key that no grade has used yet costs nothing.

**One limit from the baseline.** The owner's recent days all had two
sections, `code_review` and `design_comparison`. So `security_review`,
`plan_review` and `pseudocode_to_code` will produce keys only on days long
enough to hold a third or fourth section. The owner is the app's only user
and won't add those kinds to their own days just to collect keys. **The
owner decided** on 2026-10-28 that the read between the PRs uses drafted
sections for those three kinds: `script/draft_key_samples.rb` drafts one
kind at a time through the production retry route, writes no day and
no history, and its output goes to the reader (see "Drafted sections for
the rarer kinds" below). `code_review` is read from real days.

**Departure from the spec, which PR 2's description must state:** the
keyed-against-unkeyed calibration is a new mode,
`script/compare_models.rb review_calibration_keys`, where the spec describes
a `--without-keys` pass on `review_calibration`. The new mode grades only
the two extra answers per fixture both ways, so it costs 12 calls for each
turned-on kind (48 with all four) where re-running the whole calibration
without keys would cost another 40 plus the extras, and `review_calibration` itself stays as it is.

## PR 1. Store the keys, used by nothing yet

### Step 0. Before writing code

- Branch from `main`.
- Read `ExerciseSection::DesignComparison` and
  `ExerciseSection::AmbiguityHunt` again. Their keys are the pattern to
  copy: the guidance line, `.answer_key_fields` and `.reject_unusable!`.

### Step 1. Normalizing a key: `PlantedKey`, and `.planted_key?`

**File:** `app/models/planted_key.rb`. A small pure module for the four new
keys:
- **`PlantedKey::MAX_LENGTH = 500`**, the bound on one key field.
- **`PlantedKey.text(value)`**: a stripped string, truncated to
  `MAX_LENGTH`, or nil when blank or not a string.
- **`PlantedKey.list(value, max:, &entry)`**: maps each entry through the
  block, drops nils and keeps at most `max`.

Three helpers already bound provider text: `DesignComparison#usable_text?`,
`AmbiguityHunt`'s inline strip and `ExerciseSection.normalize_scaffold`.
This PR leaves them alone, since moving them would change two working kinds
inside a PR meant to add keys. hmccutchen/code-gym-rails#597 moves them
onto `PlantedKey` later, and its code note says so.

Each of the four kinds gains `.normalize_planted_key(section)`. It returns
the cleaned key, or nil when nothing usable is left:

| Kind | Cleaned shape |
|---|---|
| `code_review` | `issue`, `why_it_matters`, `fix`, each through `PlantedKey.text`; nil unless all three survive |
| `security_review` | `vulnerability`, `exploit`, `mitigation`, likewise |
| `plan_review` | `flaws`: up to 4 entries of `flaw` and `pushback` (both required) and `category`, kept only if it is one of the three names |
| `pseudocode_to_code` | `missable_requirements`: up to 3 strings |

**In each kind's `.reject_unusable!`:**
- A usable key is written back cleaned.
- An unusable key is deleted, and the section stays. `.reject_unusable!`
  never raises over a key.

Each of the four kinds returns `[ "answer_key" ]` from `.answer_key_fields`,
and `true` from `.planted_key?`. The base class answers `false` in one line.
That line takes `app/models/exercise_section.rb` from 301 lines to 302, and
the PR description says so: the per-kind fact belongs in the registry, and
splitting the file isn't this PR's job.

**Specs:**
- `planted_key_spec`: bounds, blanks, non-strings and the list cap.
- One spec per kind, as a table: a usable key, each field missing, wrong
  types, an over-long string, an unknown category, and an empty list. Every
  row checks that the section survives.
- `exercise_section_spec`:
  - `.all_answer_key_fields`: the first expectation (exactly `answer_key`
    and `planted_ambiguities`) still holds. The second, that every kind
    except design comparison and ambiguity hunt returns no key field, fails
    on purpose. Change it to list the four kinds that keep none:
    `pattern`, `challenge`, `architecture` and `parsons_problem`.
  - every `.planted_key?` kind lists `answer_key` in `.answer_key_fields`,
    so the two can't disagree.

### Step 2. The generation schema and guidance

- Each kind's `.schema_fragment` gains its `answer_key` object, keeping the
  indentation contract. The descriptions of `issue`, `vulnerability` and
  `flaw` ask for the quoted code or plan text in backticks.
- Each kind's `.generation_guidance` gains the hidden-data line, worded like
  `ambiguity_hunt`'s: the key is never restated, hinted at or echoed in the
  question, scenario, teaching note or diagram. It quotes the code or plan
  text in backticks rather than citing line numbers.
- **Snapshots:** re-record the generation prompt snapshots under
  `spec/fixtures/prompt_snapshots/`. 261 of the 263 carry the `code_review`
  fragment, so reading every diff by eye isn't a real check. Instead:
  - a throwaway script strips the four new fragments and their guidance
    lines from each diff and asserts nothing else changed
  - read one snapshot per kind and mode in full
  - anything beyond the four fragments and their guidance lines is a stop
    condition
- **`FakeService::EXERCISE_PROBLEM_SET`** gains a key for each of the four
  kinds, with backticked quotes that appear in its snippet or plan, so every
  downstream spec carries real keys.

### Step 3. The quote check

- Each of the four kinds gains `.unquoted_key_parts(section)`. It takes the
  backticked spans in `issue`, `vulnerability` or each `flaw`, and returns
  the ones not found, with whitespace collapsed, in the code or plan as
  formatted.
  - **No backticked span:** that counts as one unquoted part (owner's
    decision, recorded in the spec).
  - **Kinds that quote no code or plan:** `pseudocode_to_code` returns an
    empty list.
- **A miss keeps the key.** The quote check only reports; it never deletes
  or changes a key (spec section 8).
- **Specs:** each kind's hook, as a table: found, not found, whitespace
  differences, and no backticked span.

### Step 4. Recording each key's outcome

- **`ProblemSetIngest::Result`** gains `key_notes`, a list of
  `ProblemSetIngest::KeyNote = Data.define(:key, :language, :outcome)`. Every
  section whose kind is `.planted_key?` gets exactly one note:
  - `missing`: no `answer_key` after `.reject_unusable!`, whether the
    provider sent none or step 1 dropped it. Ingest reads the field after
    the hook, so `.reject_unusable!` needs no new return value.
  - `quote_missing`: a key whose `.unquoted_key_parts` isn't empty.
  - `ok`: otherwise.
- `ProblemSetIngest#reject_if_unusable` already runs after `#format_code!`,
  so the quote check sees the code as shown. `ProblemSetIngest` asks
  `.planted_key?` and names no kind.
- **Why a note and not an `Unusable`:** `unusable_sections` feeds the "No
  usable section left" error and the `[unusable_section]` log, and every
  entry in it is a dropped section. A key problem never drops a section.
- **Logging:** `GenerationDiagnostics#key_notes(notes)` logs one line per
  note, `answer_key=<outcome> kind=… language=… user=…`, in the spec's
  format. The line carries no key text. The quote threshold is counted
  straight from these lines.
- **Both callers pass the notes on:**
  - `ExerciseDraft.call`, the same way it hands over `unusable_sections`
  - `ExerciseDraft.retry_section`, which today returns only the retried
    section and drops the rest of the ingest result. It logs the result's
    `key_notes` before returning, and its return shape doesn't change, so
    `JudgedGeneration` is untouched.

**Specs:**
- `problem_set_ingest_spec`:
  - one note per keyed section: `ok`, a dropped key as `missing`, a key the
    provider never sent as `missing`, and an unquoted key as `quote_missing`
    with the key kept
  - a re-indented snippet still matches its key's quote, which proves the
    check runs after formatting
  - no note for a kind that isn't `.planted_key?`
- `generation_diagnostics_spec`: the log line's shape, and that no key text
  appears in it.
- `exercise_draft_spec`: a retried section's key note is logged.

### Step 5. A key never reaches anything else

**Specs, one per strip site in the spec's section 5:**
- `section_judge_prompt_spec`: for each of the four kinds, a sentinel in
  every key field never reaches the judge's prompt.
- `judged_generation_spec`: an edited section keeps its `answer_key`
  unchanged.
- `pseudocode_prompt_spec`: a keyed section's critique and translation
  requests carry no key text.
- `section_rendering_characterization_spec`:
  - `ANSWER_KEY_MARKERS` gains each new kind's key text
  - its fixtures today have no review, so none of its renders is a reviewed
    page. Add a reviewed render, with `ai_review` for every section, and
    check that none of the four new keys' markers appears on it either.
    `design_comparison`'s key is left out of that check, since it is shown
    after review on purpose.
- `section_context_spec`: already fills every listed key field with a
  sentinel; it must still pass with no change.

**Grading:** none of the four kinds' `.review_context` reads the key yet. A
spec pins that the review prompt for a keyed section is byte-identical to
the same section without a key. That makes the PR 1 boundary a tested
fact.

### Step 6. The key sheet export

- `script/export_review_baseline.rb --key-sheet` writes one entry per keyed
  section the owner has already had reviewed (`#section_reviewed?`). It
  takes up to `--per-kind` of each kind, newest first.
- **Each entry:** the kind, scenario, question, the code or plan as shown
  (`snippet` with `current_schema` for a migration, `plan_excerpt`, or
  `problem_statement`), and `answer_key`.
- **Nothing else:** no answer, rating, review, self-rating or date.
- It runs in the same `ReviewBaselineExport.read_only` transaction.
- **Spec:** the output holds none of the forbidden fields, checked with a
  sentinel in each, and covers only reviewed sections.

### Step 7. Measuring the generation's added cost

**The owner decided** on 2026-10-28 to measure it from usage rows instead of
extra calls: after PR 1 deploys, a read-only query the owner approves
compares the output tokens on the owner's `generate_exercise` usage rows
from the week before and the week after. The plan below is kept for the
record.

- One real generation per language on the owner's key, run with
  `script/compare_models.rb generate USER_ID`. It prints problem sets
  without keys and the token counts.
- **Ask the owner before running it.** It bills two candidate models.
- Compare the output tokens with a generation from before this branch. The
  spec expects about 60–150 more per keyed section.

**Stop and come back to the owner if:**
- a reply truncates, or
- a kind's key comes back unusable in more than one run.

### Step 8. Docs, checks and the PR

**Docs:**
- `.claude/rules/generation.md`: one entry, "Stored answer keys". It covers
  what each of the four kinds stores, that nothing reads it yet, the
  backticked quotes, and the per-section key log line. It points to the
  decision record.
- `docs/decisions/stored-answer-keys.md`: the decisions from the spec,
  including the `RUBRIC_VERSION` condition, the movement threshold and the
  quote rule. It notes that PR 2 changes grading, and records the
  trade-off of reusing the `answer_key` name, which `design_comparison`
  already uses with another shape.
- Code notes for `PlantedKey` (including the three older bounding helpers
  and #597) and each kind whose key needs more than the
  code says.
- `docs/file-map.md`: the new model and the `--key-sheet` option.

**Checks:**
- `bin/rubocop` and `bin/comment-check`.
- The full unit suite once, since `ExerciseSection`, `ProblemSetIngest` and
  the prompts are shared authorities.
- `spec/system` once.
- Grep for dead locals.

**Reviews:** the critical review and the layered review, then a third agent
checks their findings before anything changes. A PR comment lists what was
fixed and rejected, and any issues opened.

**PR description:** what's stored, the boundary that nothing reads it yet,
the token measurement, and why `exercise_section.rb` grows by one line.

**Intent log:** the entry, then `compose.rb` and `check.rb`.

### Stop conditions for PR 1

- a generation snapshot diff beyond the four fragments and their guidance
  lines
- a truncated generation, or a kind's key unusable in more than one run
- any strip site that names a field instead of reading the list

## Between the PRs: is the key right?

### Drafted sections for the rarer kinds

`script/draft_key_samples.rb KIND OUT_PATH` drafts `security_review`,
`plan_review` or `pseudocode_to_code` sections for the key read. It is built
in its own PR before the read.

- **The path.** Each draft goes through `AiService#retry_section` with one
  concept from the kind's vocabulary fixed, so the key is planted by the
  retry prompt a real day sends after a rejection, and cleaned and
  quote-checked by the same ingest and `PlantedKey` code. A day's first
  drafts come from the whole-set prompt instead, so drafts show whether the
  generator plants a correct key for the kind without reproducing a first
  draft. The production judge then judges it on its own route. A
  rejected draft is left out and another is drafted, up to a cap. A draft
  that comes back without a key is left out too, and counted.
- **Where it runs.** On the owner's machine, against a local database,
  with the owner's Anthropic key in `ANTHROPIC_API_KEY`. It never runs
  against production and never reads the production database. Without
  `--run` it only prints the plan: the number of drafts, the most calls it
  can make, and a cost bound with every call at its output cap. With `--run` it makes those calls.
  **Every `--run` needs the owner's approval first,** with that call count
  and cost.
- **What it writes.** Its output, in the key sheet's shape plus each
  draft's judge outcome, goes to a file outside the repository, which is
  deleted after the read like the key sheet. It writes no `DailyExercise`,
  response or concept history, and no `ApiUsage` row: the script's service
  keeps usage in memory, for its cost line, instead of logging it. Even a
  logged row couldn't block a real day: `ApiUsage` counts are read only by
  `TrialAllowance`, which runs only for house-key calls, and by the Account
  page's spend total. `ProviderCallLimits` counts in the cache, and
  own-key accounts skip it.
- **What it doesn't prove.** That the rarer kinds' keys hold up on real
  days. The first real section of each still logs its `[planted_key]` line,
  and those lines are checked when they appear.

1. **Wait.** Keys accumulate on real days. The quote threshold applies from
   the first keyed day: count only `attempt=draft` lines of the kinds that quote (`code_review`, `security_review`, `plan_review`) with `language=ruby_rails` (owner's decision, 2026-10-28). More than 2
   `quote_missing` in the first 10 stops the work, and the owner decides
   what's next. Report the `missing` count beside it.
2. **Export the key sheet,** with the owner's approval for that export. Keep
   it outside the repository.
3. **Read.** The owner reads the Ruby `code_review` sections from real days.
   The colleague the owner chooses reads the drafted `security_review`,
   `plan_review` and `pseudocode_to_code` sections, since the owner can't
   judge those keys reliably. The spec's option B asks for about 5 per kind.
   A kind with fewer than 5 keyed sections isn't read yet. **If no reader is
   available for a kind, that kind stays off.** Each section gets
   one call: key right, key wrong, or key right but the code or plan has a
   worse flaw. For the three drafted kinds, this read is the main check.
4. **Delete the sheet.** Record only the counts, in the description of the
   PR that turns that kind on.

**Owner decides,** kind by kind, whether the counts are good enough for the
grader to read that kind's key. The spec sets no number, and none is set
here before the read. `.review_context` is per kind, so each kind is turned
on by itself: `code_review` in PR 2, and each drafted kind in its own later
PR.

## PR 2. The grader reads the keys

PR 2 turns on `code_review` only. `security_review`, `plan_review` and
`pseudocode_to_code` stay off in it, whatever their drafts' state, and join
in later PRs. Where a step below says "turned-on kinds", in PR 2 that is
`code_review` alone.

### Step 0. Before writing code

PR 2 starts only when both of these hold:
- **The `code_review` read is done:** the quote threshold has passed on the
  first 10 drafted Ruby sections of the quoting kinds, the owner has read
  about 5 real `code_review` keys, and the owner has judged the counts good
  enough.
- **The token cost is measured:** PR 1's step 7 comparison of the owner's
  `generate_exercise` usage rows, the week before against the week after
  PR 1 deployed, is done and its counts recorded.

Then:
- Branch from `main`.
- Put the `code_review` read's counts and the token-cost counts in the PR
  description draft now, so they can't be forgotten.

### Step 1. The review context line

- Each turned-on kind's `.review_context` adds "Answer key (hidden from
  the engineer, known here for grading): …" when the section has a key.
- **Snapshots:**
  - `review_prompt_spec` gains a keyed day.
  - Day A and day B stay byte-identical.
  - A keyless section of each kind renders exactly as before.
- The walkthrough prompt gets the key through the same day context. Pin
  that with one walkthrough snapshot.

### Step 2. The grading notes

- Each turned-on kind's `.grading_note` gains the keyed wording from the
  spec's section 6. That covers the main point named by the key, the "at
  least as serious" rule for a different finding in each kind's own terms,
  and `plan_review`'s main point following the same rule.
- With no key, each note returns today's text exactly, and a spec pins it.

### Step 3. Removing only the new keys, in script code

- `ReviewBaselineExport.without_planted_keys(problem_set)`, in
  `script/review_baseline_export.rb`, drops `answer_key` only from sections
  whose kind is `.planted_key?`. It keeps `design_comparison`'s
  `answer_key` and `ambiguity_hunt`'s `planted_ambiguities`. Only the
  scripts use it, so it stays out of the app's models.
- **Spec:** both of those keys survive, and all four new ones go.

### Step 4. Calibration fixtures

Steps 4 to 7 cover only the kinds being turned on. A kind left off, for
want of a reader or of keyed sections, gets no fixture, check or run, and
doesn't hold up the others.

For `code_review`, the fixtures sit beside the Measuring step on real days.
For the three drafted kinds they are a guard, not the main check: the key
read between the PRs is. A fixture catches a grader that misreads a key it
has, and the read decides whether the keys are right at all.

- One new file in `spec/fixtures/review_calibration/` per turned-on kind, each
  with a key, the `complete`, `partial` and `miss` answers, and the two
  extra answers from the spec's table: one comparable in severity, one
  clearly lesser, each with its expected rating.
- The two existing fixtures stay untouched.

### Step 5. Checking the fixtures

Before anything is run (spec section 6), the owner checks the `code_review`
fixture and the colleague checks the other turned-on kinds', for the same
reason the colleague reads those keys:
- both alternative flaws really exist in the snippet or plan
- the comparable one really is as serious as the keyed one

The outcome goes in the PR description draft. A fixture that fails is fixed
before step 7.

### Step 6. The keyed-against-unkeyed runs

- **`script/compare_models.rb review_calibration_keys`:** grades each
  extra answer 3 times as written and 3 times through
  `without_planted_keys`, then prints each answer's ratings both ways. That
  is 12 calls for each turned-on kind, 48 with all four. One normal
  `review_calibration` run is 40.
- **`script/regrade_review_baseline.rb --without-keys`:** applies
  `without_planted_keys` to every day before grading, for step 8.
- **`script/export_review_baseline.rb --keyed-only`:** keeps only sections
  whose kind is `.planted_key?` and that carry an `answer_key`, filtering
  before the per-kind limit, so step 8 regrades the keyed sample and not
  older keyless sections that fill a short kind. Each day keeps its whole
  problem set, answers and ratings for context. The `--key-sheet` export
  can't stand in for it, since it carries no answers.
- **Specs:**
  - both regrade modes against the Faraday stub, as `model_comparison_spec`
    does today, with no provider call
  - `--keyed-only` leaves out an older keyless section of a keyed kind and
    a keyless kind, keeps the day's other sections as context, and still
    takes up to the per-kind limit

### Step 7. Running the calibration

- **Ask the owner first,** with the call count and cost for the kinds being
  turned on. With all four it is 88 calls on the owner's key, about $1.15.
- Run `review_calibration`, then `review_calibration_keys`.

**Stop and come back to the owner if:**
- any fixture's answer moves off its expected rating
- for any kind, the keyed grader rates the comparable answer lower than the
  unkeyed grader, by typical rating over the 3 runs
- for any kind, the keyed grader rates the lesser answer as meeting the
  keyed point: `developing` or higher for `code_review`, `security_review`
  and `plan_review`, or `solid` or higher for `pseudocode_to_code`

### Step 8. Measuring, before PR 2 merges

PR 1's days already carry keys, so the movement check runs on them with this
branch's code, and keyed grading never reaches production before it passes.
That way neither `CompetencyGate::Evidence` nor `LevelSuggestion::Evidence`
reads a keyed grade under the unchanged `RUBRIC_VERSION` until the check
has passed (owner's decision, after review).

1. **Export** with `--keyed-only` (step 6), with the owner's approval:
   keyed sections, up to 10 per kind, read-only, saved outside the
   repository.
2. **Regrade on this branch,** on the owner's machine with the export copied
   down and the owner's key in the provider's environment variable: each
   section 5 times as stored and 5 times with `--without-keys`. Ask the
   owner first, with the plan output's call count and cost.
3. **Compare, by kind,** in counts:
   - how many sections change rating between runs, with and without the key
   - how many sections' typical rating differs between the two, and in
     which direction
4. **Systematic movement** is at least 3 sections in one kind differing in
   the same direction, beyond the unkeyed run's own run-to-run change on
   those sections. If that happens, stop: PR 2 doesn't merge, and the
   `RUBRIC_VERSION` decision is reopened with the owner.
5. **Delete every export.** Only the counts go into the PR description.

In PR 2 this measures `code_review` only. The three drafted kinds' own
check is in their later PRs.

### Step 9. Docs, checks and the PR

The docs below name `code_review` as the one kind turned on, and say the
other three are off until their later PRs.

**Docs:**
- `docs/decisions/stored-answer-keys.md`: the grading half, with the
  calibration counts and the kinds turned on.
- `.claude/rules/review.md`: one line saying the turned-on kinds' grading
  notes read the key, with the severity rule.
- `docs/decisions/grading-rubric.md`: a note that `RUBRIC_VERSION` stays
  unchanged, and the condition it stays under.

**Checks:** as in PR 1, plus `script/compare_models.rb review_calibration`
in the PR description.

**Reviews:** the two reviews, the separate check of their findings, and the
findings comment.

**PR description:** the key-read counts, the fixture check, the calibration
counts, the Measuring counts, the departure above, and that `RUBRIC_VERSION`
is unchanged and why.

**Intent log:** the entry, then `compose.rb` and `check.rb`.

## Later PRs: the drafted kinds join

Each of `security_review`, `plan_review` and `pseudocode_to_code` is turned
on in a PR of its own, after PR 2 has merged. A kind's PR starts only when:
- its drafts have been read: the colleague the owner chose has read about 5
  drafted sections of it (see "Between the PRs"), and the owner has judged
  the counts good enough. A kind with no available reader stays off.

That PR repeats PR 2's steps 1 and 2 for the one kind, its steps 4 to 7 with
that kind's fixture and its keyed calibration (12 calls), and the docs in
step 9. Steps 3 and 6's scripts already exist from PR 2.

**Real graded sections, in place of step 8.** Count the owner's graded
sections of the kind, all and those that carry a key, with a read-only query
the owner approves. Only sections generated after PR 1 deployed carry a key,
so older ones can't be regraded keyed. If any keyed graded section exists, it
gets the same keyed-against-unkeyed regrade as a small sample, and its counts
go in the PR description. It is too few for the systematic-movement rule, so
it is reported, not ruled on. If none exists, the PR description says so.
