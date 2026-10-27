# Implementation plan: stored answer keys

This plan builds `docs/stored-answer-keys-spec-2026-10-27.md` in two PRs from
`main`. Within each PR, work the steps in order. Each step is a commit that
passes its own specs, so the branch stays green throughout.

**Why two PRs.** The spec's recommended check on whether keys are right is a
sampled read by people (section 8, option B). That read can only happen
once keys exist on real sections.
- **PR 1** stores keys but gives them to nothing: not the grader, not the
  page, not any prompt. Keys pile up on real days while grading stays
  exactly as it is today.
- **Between the PRs,** the owner and a colleague read a sample.
- **PR 2** lets the grader read them, only if that read says the keys are
  right often enough.

A wrong key that no grade has used yet costs nothing.

**One limit from the baseline.** The owner's recent days all had two
sections, `code_review` and `design_comparison`. So `security_review`,
`plan_review` and `pseudocode_to_code` will produce keys only on days long
enough to hold a third or fourth section. **Owner decides,** before PR 1
merges, whether to:
- wait for those kinds to come up,
- raise the daily section count for a while, or
- measure the four keyed kinds on `code_review` alone and read the others
  as directional.

## PR 1. Store the keys, used by nothing yet

### Step 0. Before writing code

- Branch from `main`.
- Check hmccutchen/code-gym-rails#592. If its single reader for the
  grader's original review has merged, the key sheet in step 6 doesn't need
  it, but later steps follow its paths.
- Read `ExerciseSection::DesignComparison` and
  `ExerciseSection::AmbiguityHunt` again. Their keys are the pattern to
  copy: the guidance line, `.answer_key_fields` and `.reject_unusable!`.

### Step 1. Normalizing a key: `PlantedKey`

**File:** `app/models/planted_key.rb`. A small pure module, the one place a
key's text is bounded:
- **`PlantedKey.text(value, limit: 500)`**: a stripped string, truncated to
  the limit, or nil when blank or not a string.
- **`PlantedKey.list(value, max:, &entry)`**: maps each entry through the
  block, drops nils and keeps at most `max`.

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

Each of the four kinds returns `[ "answer_key" ]` from `.answer_key_fields`.

**Specs:**
- `planted_key_spec`: bounds, blanks, non-strings and the list cap.
- One spec per kind, as a table: a usable key, each field missing, wrong
  types, an over-long string, an unknown category, and an empty list. Every
  row checks that the section survives.
- `exercise_section_spec`, `.all_answer_key_fields`: the first expectation
  (exactly `answer_key` and `planted_ambiguities`) still holds. The second,
  that every kind except design comparison and ambiguity hunt returns no key
  field, fails on purpose. Change it to list the six kinds that keep none.

### Step 2. Recording a missing key

- **`ProblemSetIngest::Result`** gains `key_notes`, a list of
  `ProblemSetIngest::KeyNote = Data.define(:key, :problem)`. `problem` is
  `"missing"` (step 1 dropped the key) or `"quote_missing"` (step 4).
- **`ExerciseDraft`** passes `key_notes` to
  `GenerationDiagnostics#key_notes(notes)`, the same way it hands over
  `unusable_sections`.
- **The log lines** are `[answer_key] user=… section=… problem=missing` and
  `problem=quote_missing`. They carry no key text.

**Specs:**
- `problem_set_ingest_spec`: a dropped key yields one note and keeps the
  section.
- `generation_diagnostics_spec`: the log line's shape, and that no key text
  appears in it.

### Step 3. The generation schema and guidance

- Each kind's `.schema_fragment` gains its `answer_key` object, keeping the
  indentation contract.
- Each kind's `.generation_guidance` gains the hidden-data line, worded like
  `ambiguity_hunt`'s: the key is never restated, hinted at or echoed in the
  question, scenario, teaching note or diagram, and it quotes code or plan
  text rather than citing line numbers.
- **Snapshots:** re-record the generation prompt snapshots under
  `spec/fixtures/prompt_snapshots/`, reading every diff. Anything beyond the
  four fragments and their guidance lines is a stop condition.
- **`FakeService::EXERCISE_PROBLEM_SET`** gains a key for each of the four
  kinds, so every downstream spec carries real keys.

### Step 4. The quote check

- Each of the four kinds gains `.unquoted_key_parts(section)`. It takes the
  backticked spans in `issue`, `vulnerability` or each `flaw`, and returns
  the ones not found, with whitespace collapsed, in the code or plan as
  formatted.
  - **No backticked span:** that counts as one unquoted part, since the
    spec asks the key to quote.
  - **Kinds that quote no code or plan:** `pseudocode_to_code` returns an
    empty list.
- `ProblemSetIngest#reject_if_unusable` already runs after `#format_code!`.
  It calls the hook there, and any miss becomes a `quote_missing` key note.
  `ProblemSetIngest` itself names no kind.
- **Specs:**
  - each kind's hook, as a table: found, not found, whitespace differences,
    and no quote
  - ingest: a re-indented snippet still matches its key's quote, which
    proves the check runs after formatting

### Step 5. A key never reaches anything else

**Specs, one per strip site in the spec's section 5:**
- `section_judge_prompt_spec`: for each of the four kinds, a sentinel in
  every key field never reaches the judge's prompt.
- `judged_generation_spec`: an edited section keeps its `answer_key`
  unchanged.
- `pseudocode_prompt_spec`: a keyed section's critique and translation
  requests carry no key text.
- `section_rendering_characterization_spec`: `ANSWER_KEY_MARKERS` gains
  each kind's key text, and every render stays free of it.
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
  what each of the four kinds stores, that nothing reads it yet, and the key
  notes. It points to the decision record.
- `docs/decisions/stored-answer-keys.md`: the decisions from the spec,
  including the `RUBRIC_VERSION` condition and the movement threshold. It
  notes that PR 2 changes grading.
- Code notes for `PlantedKey` and each kind whose key needs more than the
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
and the token measurement.

**Intent log:** the entry, then `compose.rb` and `check.rb`.

### Stop conditions for PR 1

- a generation snapshot diff beyond the four fragments and their guidance
  lines
- a truncated generation, or a kind's key unusable in more than one run
- any strip site that names a field instead of reading the list

## Between the PRs: is the key right?

1. **Wait.** Keys accumulate on real days. The quote check's threshold
   applies from the first keyed day: more than 2 misses in the first 10
   keyed Ruby sections stops the work, and the owner decides what's next.
2. **Export the key sheet,** with the owner's approval for that export. Keep
   it outside the repository.
3. **Read.** The owner reads the Ruby `code_review` sections. The colleague
   the owner chooses reads the other three kinds. Each section gets one
   call: key right, key wrong, or key right but the code or plan has a worse
   flaw.
4. **Delete the sheet.** Record only the counts, in PR 2's description.

**Owner decides** whether the counts are good enough to start PR 2. There's
no number for it in the spec. The baseline's noise floor, about one grade in
75 moving by one level, is a reference: a key wrong more often than that
would add more error than it removes.

## PR 2. The grader reads the keys

### Step 0. Before writing code

- Branch from `main`, after PR 1 and the read above.
- Put the read's counts in the PR description draft now, so they can't be
  forgotten.

### Step 1. The review context line

- Each of the four kinds' `.review_context` adds "Answer key (hidden from
  the engineer, known here for grading): …" when the section has a key.
- **Snapshots:**
  - `review_prompt_spec` gains a keyed day.
  - Day A and day B stay byte-identical.
  - A keyless section of each kind renders exactly as before.
- The walkthrough prompt gets the key through the same day context. Pin
  that with one walkthrough snapshot.

### Step 2. The grading notes

- Each of the four kinds' `.grading_note` gains the keyed wording from the
  spec's section 6. That covers the main point named by the key, the "at
  least as serious" rule for a different finding in each kind's own terms,
  and `plan_review`'s main point following the same rule.
- With no key, each note returns today's text exactly, and a spec pins it.

### Step 3. Removing only the new keys: `.planted_key?`

- Each kind gains `.planted_key?`: false by default, true for the four.
- `ExerciseSection.without_planted_keys(problem_set)` drops `answer_key`
  only from sections whose kind is `.planted_key?`. It keeps
  `design_comparison`'s `answer_key` and `ambiguity_hunt`'s
  `planted_ambiguities`.
- **Spec:** both of those keys survive, and all four new ones go.

### Step 4. Calibration fixtures

- Four new files in `spec/fixtures/review_calibration/`, one per kind, each
  with a key, the `complete`, `partial` and `miss` answers, and the two
  extra answers from the spec's table: one comparable in severity, one
  clearly lesser, each with its expected rating.
- The two existing fixtures stay untouched.
- **Whoever reviews the PR** checks that both alternative flaws really
  exist in each snippet or plan, and that the comparable one really is as
  serious as the keyed one.

### Step 5. The keyed-against-unkeyed runs

- **`script/compare_models.rb review_calibration_keys`:** grades each
  extra answer 3 times as written and 3 times through
  `without_planted_keys`, then prints each answer's ratings both ways. That
  is 48 calls. One normal `review_calibration` run is 40.
- **`script/regrade_review_baseline.rb --without-keys`:** applies
  `without_planted_keys` to every day before grading. Measuring needs it
  after merge.
- **Specs:** both modes against the Faraday stub, as `model_comparison_spec`
  does today, with no provider call.

### Step 6. Running the calibration

- **Ask the owner first.** It is 88 calls on the owner's key, about $1.15.
- Run `review_calibration`, then `review_calibration_keys`.

**Stop and come back to the owner if:**
- any fixture's answer moves off its expected rating
- for any kind, the keyed grader rates the comparable answer lower than the
  unkeyed grader, by typical rating over the 3 runs
- for any kind, the keyed grader rates the lesser answer as meeting the
  keyed point: `developing` or higher for `code_review`, `security_review`
  and `plan_review`, or `solid` or higher for `pseudocode_to_code`

### Step 7. Docs, checks and the PR

**Docs:**
- `docs/decisions/stored-answer-keys.md`: the grading half, with the
  calibration counts.
- `.claude/rules/review.md`: one line saying the four kinds' grading notes
  read the key, with the severity rule.
- `docs/decisions/grading-rubric.md`: a note that `RUBRIC_VERSION` stays
  unchanged, and the condition it stays under.

**Checks:** as in PR 1, plus `script/compare_models.rb review_calibration`
in the PR description.

**Reviews:** the two reviews, the separate check of their findings, and the
findings comment.

**PR description:** the key-read counts, the calibration counts, and that
`RUBRIC_VERSION` is unchanged and why.

**Intent log:** the entry, then `compose.rb` and `check.rb`.

## After PR 2 merges: Measuring

From the spec, after about two weeks of keyed days:
1. **Export,** with approval: keyed sections, up to 10 per kind.
2. **Regrade each section** 5 times as stored and 5 times with
   `--without-keys`.
3. **Compare, by kind,** in counts:
   - how many sections change rating between runs, with and without the key
   - how many sections' typical rating differs between the two, and in
     which direction
4. **Systematic movement** is at least 3 sections in one kind differing in
   the same direction, beyond the unkeyed run's own run-to-run change on
   those sections. If that happens, say so and reopen the `RUBRIC_VERSION`
   decision before the competency gate or level suggestions read
   keyed-era ratings.
5. **Delete every export.**
