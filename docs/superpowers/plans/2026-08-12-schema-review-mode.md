# Schema-Review Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `code_review` a third content mode — a proposed migration carrying a planted data-modeling flaw — selected by one weighted roll in `DailyPlan`, and flatten the third-slot rotation to equal weights.

**Architecture:** `DailyPlan` rolls `code_review_mode` alongside `third` and `fourth` and returns it on `Result`. `AiService` threads it into the prompt, where `ExerciseSection::CodeReview.generation_guidance` renders the mode-specific instruction. Five data-modeling concepts fold into both language vocabularies; only schema-review days are scoped to them. Getting there requires first giving `CodeReview` and `Pattern` their own guidance facets, which dissolves issue #81.

**Tech Stack:** Rails 8.0.5, RSpec, PostgreSQL. No new dependencies. No database migration.

## Global Constraints

- **No database migration.** Vocabularies are frozen Ruby constants; concepts are strings in existing `jsonb` and `concept_masteries.concept`.
- **No new `ExerciseSection` kind, no new `ConceptBucket`, no `ConceptBucket` change.** The section key stays `code_review`.
- **No mastery-tier changes.** New concepts flow through existing machinery.
- **No `FakeService` change.**
- **Prompt snapshots rebaseline exactly twice** — Task 2 and Task 6. Never in any other task. Rebaseline with `UPDATE_PROMPT_SNAPSHOTS=1 bundle exec rspec spec/services/generation_prompt_characterization_spec.rb`.
- **Concept names, verbatim:** `missing_index`, `wrong_cardinality`, `missing_constraint`, `denormalization_tradeoffs`, `unsafe_migration`.
- **Mode names, verbatim:** `:application_code`, `:test_file`, `:schema_review`.
- Run the full suite with `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`. Lint with `bundle exec rubocop app/ spec/`.
- Branch is `feat/schema-review-mode`, already created from `main`.
- **Both planning docs must be deleted before the PR is opened** (Task 8): the spec at `docs/superpowers/specs/2026-08-12-schema-review-mode-design.md` and this plan at `docs/superpowers/plans/2026-08-12-schema-review-mode.md`. They are committed so they can be read during the work; they do not land in the PR diff.

## File Structure

| File | Responsibility after this work |
| --- | --- |
| `app/services/daily_plan.rb` | Owns all three weighted rolls via one `roll_weighted`; `Result` carries `code_review_mode` |
| `app/models/exercise_section.rb` | Base `generation_guidance(vocabulary:, label:, mode: nil)` — no more `language_vocabulary:` |
| `app/models/exercise_section/code_review.rb` | Its own guidance, mode-aware — the only kind reading `mode` |
| `app/models/exercise_section/pattern.rb` | Its own guidance |
| `app/models/exercise_section/{architecture,challenge,parsons_problem}.rb` | Guidance names only their own vocabulary |
| `app/services/problem_set_ingest.rb` | `vocabulary_for(section_key, language, mode: nil)` |
| `app/services/ai_service.rb` | `DATA_MODELING_CONCEPTS`, `schema_artifact` config, threads the mode, mode-aware retention annotation |
| `spec/services/generation_prompt_characterization_spec.rb` | Gains the mode axis: 16 → 48 snapshots |

---

### Task 1: Repoint code comments at design docs that do not exist

Unrelated to the feature; lands first and alone. `docs/superpowers/specs/` is untracked, so six comments cite paths that resolve to nothing. Two have a tracked counterpart under `docs/superpowers/plans/`; the rest are dropped. Files under `docs/superpowers/plans/` are left alone — they were accurate when written and are historical records.

**Files:**
- Modify: `app/models/user.rb:156`
- Modify: `app/controllers/sessions_controller.rb:14`
- Modify: `app/controllers/responses_controller.rb:324`, `:447`
- Modify: `app/services/ai_service.rb:484`, `:702`

**Interfaces:**
- Consumes: nothing
- Produces: nothing

- [ ] **Step 1: Confirm which targets exist**

```bash
ls docs/superpowers/plans/ | grep -E "touch-device|difficulty-diagnostics"
```

Expected: `2026-08-03-touch-device-gated-login-code.md` and `2026-08-11-difficulty-diagnostics-logging.md` both listed. The duck-thread and mastery-loop specs have no counterpart.

- [ ] **Step 2: Repoint the two that have counterparts**

In `app/controllers/sessions_controller.rb:14`, change:

```ruby
  # See docs/superpowers/specs/2026-08-03-touch-device-gated-login-code-design.md
```

to:

```ruby
  # See docs/superpowers/plans/2026-08-03-touch-device-gated-login-code.md
```

In `app/controllers/responses_controller.rb:447` and `app/services/ai_service.rb:702`, change `docs/superpowers/specs/2026-08-11-difficulty-diagnostics-logging-design.md` to `docs/superpowers/plans/2026-08-11-difficulty-diagnostics-logging.md`.

- [ ] **Step 3: Drop the three with no counterpart**

`app/models/user.rb:156` — delete the trailing sentence so the comment reads:

```ruby
  # concept today.
```

`app/controllers/responses_controller.rb:324` and `app/services/ai_service.rb:484` both end with `# docs/superpowers/specs/2026-08-06-duck-thread-design.md.` on its own line, preceded by a line ending `See`. Delete the path line and the trailing ` See` from the line above it, so each comment ends at the previous sentence.

- [ ] **Step 4: Verify no dangling references remain in app/**

```bash
grep -rn "docs/superpowers/specs/" app/
```

Expected: no output.

- [ ] **Step 5: Run the suite**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
Expected: 1198 examples, 0 failures. Comments only — nothing should move.

- [ ] **Step 6: Commit**

```bash
git add app/
git commit -m "Repoint code comments at design docs that exist

docs/superpowers/specs/ is untracked, so six comments cited paths that
resolve to nothing. Two have a tracked counterpart under plans/ and are
repointed; the rest are dropped rather than left pointing at nothing.

Files under docs/superpowers/plans/ are left as-is — they were accurate
when written and are historical records, not live guidance."
```

---

### Task 2: Give CodeReview and Pattern their own guidance (fixes #81)

Every kind states its own vocabulary; none speaks for another. The misplaced `code_review`/`pattern` line vanishes because no kind has a slot for another kind's instruction, and `language_vocabulary:` disappears with it.

**Files:**
- Modify: `app/models/exercise_section.rb` (base `generation_guidance`)
- Modify: `app/models/exercise_section/code_review.rb`, `pattern.rb`, `architecture.rb`, `challenge.rb`, `parsons_problem.rb`, `security_review.rb`, `plan_review.rb`, `ambiguity_hunt.rb`
- Modify: `app/services/ai_service.rb` (`generation_guidance_for`, prompt body)
- Modify: `spec/models/exercise_section_spec.rb`
- Modify: `spec/services/ai_service_spec.rb`
- Rebaseline: `spec/fixtures/prompt_snapshots/*.txt` (16 files)

**Interfaces:**
- Consumes: `ProblemSetIngest.vocabulary_for(section_key, language)` (existing)
- Produces: `ExerciseSection.generation_guidance(vocabulary:, label:, mode: nil)` — the `mode:` keyword is accepted by all kinds from here on but read by none until Task 6.

- [ ] **Step 1: Write the failing tests**

In `spec/models/exercise_section_spec.rb`, inside `describe ".generation_guidance"`, **delete** this block entirely (it pins behavior being removed):

```ruby
    [ ExerciseSection::CodeReview, ExerciseSection::Pattern ].each do |kind|
      it "raises for #{kind.key}, which carries no guidance" do
        expect { guidance(kind, vocabulary: RAILS_VOCAB) }
          .to raise_error(NotImplementedError, /generation_guidance/)
      end
    end
```

Replace the `guidance` helper in that describe block with one that has no `language_vocabulary`:

```ruby
    def guidance(kind, vocabulary:, label: "Ruby/Rails", mode: nil)
      kind.generation_guidance(vocabulary: vocabulary, label: label, mode: mode)
    end
```

Then add:

```ruby
    describe ExerciseSection::CodeReview do
      it "names its own vocabulary and no other kind's" do
        text = guidance(described_class, vocabulary: RAILS_VOCAB)
        expect(text).to include("Choose the code_review concept from this vocabulary")
        expect(text).to include("n_plus_one")
        expect(text).not_to include("pattern concept")
      end
    end

    describe ExerciseSection::Pattern do
      it "names its own vocabulary and no other kind's" do
        text = guidance(described_class, vocabulary: RAILS_VOCAB)
        expect(text).to include("Choose the pattern concept from this vocabulary")
        expect(text).to include("n_plus_one")
        expect(text).not_to include("code_review concept")
      end
    end

    # Issue #81: every kind's guidance now speaks only for itself.
    it "has no kind stating another kind's vocabulary" do
      ExerciseSection.all.each do |kind|
        next if [ ExerciseSection::CodeReview, ExerciseSection::Pattern ].include?(kind)

        text = guidance(kind, vocabulary: ProblemSetIngest.vocabulary_for(kind.key, "ruby_rails"))
        expect(text).not_to include("code_review and pattern concepts"), "#{kind.key} still speaks for code_review"
        expect(text).not_to include("each section's concept"), "#{kind.key} still speaks for every section"
      end
    end
```

Also update the two existing issue-#81 examples in that file — `still carries code_review and pattern's vocabulary line (issue #81)` under `ExerciseSection::Architecture` and `says nothing about code_review and pattern's vocabulary (issue #81)` under `ExerciseSection::SecurityReview`. Delete the Architecture one outright (the line it asserts is being removed). Keep the SecurityReview one but drop its `(issue #81)` suffix — the assertion stays true and is now the norm rather than the exception.

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/models/exercise_section_spec.rb`
Expected: FAIL — `NotImplementedError` from `CodeReview.generation_guidance`, and `ArgumentError: unknown keyword: :mode` from kinds whose signature still takes `language_vocabulary:`.

- [ ] **Step 3: Change the base contract**

In `app/models/exercise_section.rb`, replace the `generation_guidance` doc comment and signature with:

```ruby
    # The generation prompt's instruction block for this kind — how to write
    # it, and which vocabulary its concept comes from. Every kind states its
    # own vocabulary and none speaks for another, which is what keeps the
    # instruction a reader sees for one section independent of what rolled
    # into another (see issue #81, fixed by that rule).
    #
    # `vocabulary` is this kind's own, resolved by the caller from
    # .vocabulary_key. `mode` is the rolled content mode, for kinds that have
    # one — only code_review does today.
    def generation_guidance(vocabulary:, label:, mode: nil)
      raise NotImplementedError, "#{self} must implement .generation_guidance"
    end
```

- [ ] **Step 4: Add guidance to CodeReview and Pattern**

In `app/models/exercise_section/code_review.rb`:

```ruby
  def self.generation_guidance(vocabulary:, label:, mode: nil)
    <<~GUIDANCE.chomp
      - Choose the code_review concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
    GUIDANCE
  end
```

In `app/models/exercise_section/pattern.rb`:

```ruby
  def self.generation_guidance(vocabulary:, label:, mode: nil)
    <<~GUIDANCE.chomp
      - Choose the pattern concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
    GUIDANCE
  end
```

- [ ] **Step 5: Strip the stray lines from the six rolled kinds**

Change every rolled kind's signature from `(vocabulary:, language_vocabulary:, label:)` to `(vocabulary:, label:, mode: nil)`.

In `architecture.rb`, delete this line from the heredoc and delete the seven-line `# The 'code_review and pattern' line below...` comment above the method:

```
      - Choose the code_review and pattern concepts from this vocabulary, exactly one each: #{language_vocabulary.join(", ")}
```

In `challenge.rb`, replace:

```
      - Choose each section's concept from this fixed vocabulary, exactly one per section: #{language_vocabulary.join(", ")}
```

with:

```
      - Choose the challenge concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
```

and delete the `# As in ParsonsProblem, the "each section's concept" line speaks for` comment above the method.

In `parsons_problem.rb`, make the same substitution with `parsons_problem` in place of `challenge`, and delete its equivalent comment.

In `security_review.rb`, keep the guidance text unchanged and delete the `# Says nothing about code_review and pattern's vocabulary...` comment. In `plan_review.rb` and `ambiguity_hunt.rb`, change the signature only.

- [ ] **Step 6: Update the caller and the prompt body**

In `app/services/ai_service.rb`, replace `generation_guidance_for`:

```ruby
  # A kind's generation instructions. The kind's own vocabulary is resolved
  # through ProblemSetIngest.vocabulary_for — the same lookup ingest validates
  # against — so the guidance can never name a vocabulary the normalizer would
  # then rewrite a concept away from.
  def generation_guidance_for(kind, language)
    kind.generation_guidance(
      vocabulary: ProblemSetIngest.vocabulary_for(kind.key, language),
      label:      config_for(language)[:label]
    )
  end
```

In `build_exercise_prompt`, beside the existing `third_guidance` assignment, add:

```ruby
    code_review_guidance = generation_guidance_for(ExerciseSection::CodeReview, language)
    pattern_guidance     = generation_guidance_for(ExerciseSection::Pattern, language)
```

and in the PROMPT heredoc, replace:

```
      #{third_guidance}
      #{fourth_guidance}
```

with:

```
      #{code_review_guidance}
      #{pattern_guidance}
      #{third_guidance}
      #{fourth_guidance}
```

- [ ] **Step 7: Run the kind specs**

Run: `bundle exec rspec spec/models/exercise_section_spec.rb`
Expected: PASS.

- [ ] **Step 8: Rebaseline the snapshots (rebaseline 1 of 2)**

Run: `UPDATE_PROMPT_SNAPSHOTS=1 bundle exec rspec spec/services/generation_prompt_characterization_spec.rb`
Then: `git diff --stat spec/fixtures/prompt_snapshots/`
Expected: all 16 files changed, still 16 files.

Inspect one diff to confirm the change is only the vocabulary line moving:

```bash
git diff spec/fixtures/prompt_snapshots/ruby_rails__architecture__plan_review.txt
```

Expected: the `Choose the code_review and pattern concepts...` line is gone from the architecture block; two new `Choose the code_review concept...` / `Choose the pattern concept...` lines appear above it. Nothing else.

- [ ] **Step 9: Run the full suite and fix fallout**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
Expected: PASS. If `ai_service_spec.rb` has an example asserting `generation_guidance_for` passes `language_vocabulary`, update it to the new signature.

- [ ] **Step 10: Lint and commit**

```bash
bundle exec rubocop app/ spec/
git add -A
git commit -m "Give code_review and pattern their own generation guidance

Fixes #81. The instruction naming code_review and pattern's vocabulary
lived inside the third section's guidance, worded differently per third
and absent entirely on security_review days — so the model's instruction
for two fixed sections depended on an unrelated dice roll.

Rather than move that line somewhere shared, every kind now states its
own vocabulary and none speaks for another. The misplaced line has
nowhere left to live, and language_vocabulary: disappears from the
signature with it. generation_guidance gains mode:, unread until the
code_review content modes land.

Snapshots rebaselined: the vocabulary line moves, nothing else.

Closes #81"
```

---

### Task 3: Extract one weighted roll

Pure refactor, no behavior change. Two copies of the cumulative-weight loop become one, before a third is needed.

**Files:**
- Modify: `app/services/daily_plan.rb`
- Modify: `spec/services/daily_plan_spec.rb`

**Interfaces:**
- Produces: `DailyPlan.roll_weighted(weights)` (private class method) — takes an ordered Hash of `symbol => Float`, returns a key.

- [ ] **Step 1: Write the failing test**

In `spec/services/daily_plan_spec.rb`:

```ruby
  describe ".roll_weighted" do
    let(:weights) { { a: 0.5, b: 0.3, c: 0.2 } }

    def roll(value)
      allow(DailyPlan).to receive(:rand).and_return(value)
      DailyPlan.send(:roll_weighted, weights)
    end

    it "returns each key within its band" do
      expect(roll(0.0)).to eq(:a)
      expect(roll(0.49)).to eq(:b == :b ? :a : :a)
      expect(roll(0.5)).to eq(:b)
      expect(roll(0.79)).to eq(:b)
      expect(roll(0.8)).to eq(:c)
      expect(roll(0.999)).to eq(:c)
    end

    # Summing floats (0.5 + 0.3 == 0.8) can land an ulp below the boundary and
    # hand back the wrong key at the exact boundary value.
    it "is exact at a boundary that float addition would miss" do
      expect(roll(0.8)).to eq(:c)
    end

    it "falls back to the last key if rand returns 1.0" do
      expect(roll(1.0)).to eq(:c)
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/daily_plan_spec.rb -e "roll_weighted"`
Expected: FAIL with `NoMethodError` / undefined method `roll_weighted`.

- [ ] **Step 3: Replace both rollers with one**

In `app/services/daily_plan.rb`, delete `roll_third_section` and `roll_fourth_section` (and their `private_class_method` lines) and add:

```ruby
  # Cumulative weights are rounded before comparison: summing float weights
  # (0.40 + 0.20 == 0.6000000000000001) otherwise shifts each boundary by an
  # ulp and hands the wrong kind back at the exact boundary value.
  # Extracted so tests can stub it — never assert on real randomness.
  def self.roll_weighted(weights)
    r = rand
    cumulative = 0.0

    weights.each do |kind, weight|
      cumulative += weight
      return kind if r < cumulative.round(10)
    end

    weights.keys.last
  end
  private_class_method :roll_weighted
```

In `.for`, change `third = roll_third_section` to `third = roll_weighted(THIRD_SECTION_WEIGHTS)` and `fourth = roll_fourth_section` to `fourth = roll_weighted(FOURTH_SECTION_WEIGHTS)`.

- [ ] **Step 4: Update existing roller specs**

In `spec/services/daily_plan_spec.rb`, any example calling `DailyPlan.send(:roll_third_section)` or `:roll_fourth_section` must call `DailyPlan.send(:roll_weighted, DailyPlan::THIRD_SECTION_WEIGHTS)` / `...FOURTH_SECTION_WEIGHTS`. Keep their assertions unchanged — the bands have not moved yet.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
Expected: PASS. Snapshots must be untouched — verify with `git status spec/fixtures/prompt_snapshots/` showing no changes.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Extract one roll_weighted from the two slot rollers

Same cumulative-weight loop written twice, about to be written a third
time for the code_review content mode. Pure refactor: the bands and the
boundary rounding are unchanged."
```

---

### Task 4: Equal third-slot weights

**Files:**
- Modify: `app/services/daily_plan.rb`
- Modify: `spec/services/daily_plan_spec.rb`

**Interfaces:**
- Consumes: `roll_weighted` from Task 3
- Produces: nothing new

- [ ] **Step 1: Rewrite the band test for equal quarters**

In `spec/services/daily_plan_spec.rb`, replace the example `returns :architecture below 0.40, :security_review from 0.40-0.60, :challenge from 0.60-0.80, :parsons_problem from 0.80 up` and its `rand` stubs with:

```ruby
    it "returns each third in an equal quarter band" do
      {
        0.0 => :architecture, 0.24 => :architecture,
        0.25 => :security_review, 0.49 => :security_review,
        0.50 => :challenge, 0.74 => :challenge,
        0.75 => :parsons_problem, 0.99 => :parsons_problem
      }.each do |value, expected|
        allow(DailyPlan).to receive(:rand).and_return(value)
        expect(DailyPlan.send(:roll_weighted, DailyPlan::THIRD_SECTION_WEIGHTS)).to eq(expected)
      end
    end

    it "gives every third the same weight" do
      expect(DailyPlan::THIRD_SECTION_WEIGHTS.values.uniq).to eq([ 0.25 ])
    end
```

Keep the existing `values.sum` and `have_key(:parsons_problem)` examples as they are.

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/daily_plan_spec.rb -e "equal quarter"`
Expected: FAIL — `0.25` returns `:architecture` under the current 0.40 band.

- [ ] **Step 3: Change the weights**

In `app/services/daily_plan.rb`:

```ruby
  # Which third section this set gets. Equal weights: the four kinds exercise
  # different reasoning and none is the baseline the others vary from, so
  # variety beats depth-in-one-area here. This deliberately reverses an
  # earlier bias toward architecture (0.75, then 0.50, then 0.40).
  # The chosen kind is not tracked separately; the persisted third key
  # (ExerciseSection.thirds) is the record.
  THIRD_SECTION_WEIGHTS = { architecture: 0.25, security_review: 0.25, challenge: 0.25, parsons_problem: 0.25 }.freeze
```

- [ ] **Step 4: Run the full suite**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
Expected: PASS. Snapshots untouched — the characterization spec enumerates the *keys* of `THIRD_SECTION_WEIGHTS`, which have not changed. Verify with `git status spec/fixtures/prompt_snapshots/`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Give every third-slot kind equal weight

architecture 0.40 / security_review 0.20 / challenge 0.20 /
parsons_problem 0.20 becomes 0.25 each.

This deliberately reverses the bias toward architecture — 0.75, then
0.50, then 0.40 — which was a considered choice each time. It is
superseded in favour of variety, not adjusted silently. The four kinds
exercise different reasoning and none is the baseline the others vary
from, so there is no longer a reason to favour one.

FOURTH_SECTION_WEIGHTS is already 50/50 and is unchanged."
```

---

### Task 5: Add the data-modeling vocabulary and the schema artifact

Constants and config only. Nothing reads the artifact yet.

**Files:**
- Modify: `app/services/ai_service.rb`
- Modify: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Produces: `AiService::DATA_MODELING_CONCEPTS` (frozen Array of 5 Strings); `AiService::LANGUAGE_CONFIG[lang][:schema_artifact]` (String, present for `ruby_rails` and `javascript` only)

- [ ] **Step 1: Write the failing tests**

In `spec/services/ai_service_spec.rb`:

```ruby
  describe "DATA_MODELING_CONCEPTS" do
    it "holds the five data-modeling concepts" do
      expect(AiService::DATA_MODELING_CONCEPTS).to eq(%w[
        missing_index wrong_cardinality missing_constraint
        denormalization_tradeoffs unsafe_migration
      ])
    end

    # One shared list, not one per language: the Prisma artifact is relational,
    # so every concept means the same thing in both.
    it "is folded into both language vocabularies" do
      expect(AiService::RAILS_CONCEPTS).to include(*AiService::DATA_MODELING_CONCEPTS)
      expect(AiService::JS_CONCEPTS).to include(*AiService::DATA_MODELING_CONCEPTS)
    end

    it "overlaps no other closed vocabulary" do
      [ AiService::ARCHITECTURE_CONCEPTS, AiService::PLAN_REVIEW_CONCEPTS,
        AiService::AMBIGUITY_HUNT_CONCEPTS, AiService::RAILS_SECURITY_CONCEPTS,
        AiService::JS_SECURITY_CONCEPTS ].each do |other|
        expect(AiService::DATA_MODELING_CONCEPTS & other).to be_empty
      end
    end
  end

  describe "schema_artifact in LANGUAGE_CONFIG" do
    it "names a per-language artifact for the two real languages" do
      expect(AiService::LANGUAGE_CONFIG["ruby_rails"][:schema_artifact]).to eq("a Rails migration")
      expect(AiService::LANGUAGE_CONFIG["javascript"][:schema_artifact])
        .to eq("a Prisma schema change, with the migration it generates")
    end

    # Mirrors test_framework: absent for the pseudo-language buckets, which
    # never generate a code_review section.
    it "is absent for the pseudo-language buckets" do
      %w[architecture plan_review ambiguity_hunt].each do |bucket|
        expect(AiService::LANGUAGE_CONFIG[bucket][:schema_artifact]).to be_nil
      end
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "DATA_MODELING_CONCEPTS"`
Expected: FAIL — uninitialized constant.

- [ ] **Step 3: Add the constant**

In `app/services/ai_service.rb`, directly above `RAILS_CONCEPTS`:

```ruby
  # Data-modeling concepts, folded into BOTH language vocabularies rather than
  # given a bucket of their own. A bucket is not possible here: ConceptBucket
  # dispatches on section key, and this content mode's key is still
  # "code_review". Per-language mastery tracking is the accepted cost, and is
  # arguably correct — indexing and migration-safety concerns differ enough
  # between an ActiveRecord/Postgres context and a Prisma one to track apart.
  #
  # One shared list rather than two, unlike RAILS_SECURITY_CONCEPTS /
  # JS_SECURITY_CONCEPTS, whose contents genuinely differ. These do not: the
  # Prisma artifact is relational, so every entry means the same thing in both
  # languages. Two identical lists would only be somewhere to drift.
  #
  # `unsafe_migration` is operational rather than structural, and belongs
  # anyway: the artifact under review IS a migration, so its safety is in
  # frame by construction. It passes the same depth filter as the rest — a
  # lock is the easy version, backfill-then-constrain across deploys the
  # harder one, knowing when the safe path isn't worth its complexity the
  # hardest.
  DATA_MODELING_CONCEPTS = %w[
    missing_index wrong_cardinality missing_constraint
    denormalization_tradeoffs unsafe_migration
  ].freeze
```

Append `+ DATA_MODELING_CONCEPTS` to both vocabularies:

```ruby
  RAILS_CONCEPTS = %w[
    n_plus_one transaction_safety memoization service_objects scope_chaining
    idempotency authorization background_jobs caching validations
    callbacks_vs_service query_objects policy_objects indexing concurrency
    error_handling mass_assignment_protection sql_injection_prevention
    over_mocking testing_implementation_not_behavior
  ].freeze + DATA_MODELING_CONCEPTS
```

Apply the same `.freeze + DATA_MODELING_CONCEPTS` to `JS_CONCEPTS`.

- [ ] **Step 4: Add the artifact to LANGUAGE_CONFIG**

Add `schema_artifact:` to the two real languages only, beside `test_framework:`:

```ruby
    "ruby_rails" => {
      # ...existing keys...
      test_framework:    "an RSpec-style",
      schema_artifact:   "a Rails migration",
      # ...
    },
    "javascript" => {
      # ...existing keys...
      test_framework:    "a Jest/Vitest-style",
      schema_artifact:   "a Prisma schema change, with the migration it generates",
      # ...
    },
```

The JavaScript artifact is the schema change *and* its migration: `unsafe_migration` cannot be planted in a `schema.prisma`, which has no migration semantics. Add that as a comment above the key.

- [ ] **Step 5: Run the suite**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
Expected: PASS. Snapshots untouched — nothing reads `schema_artifact` yet, and the vocabulary additions only reach the prompt via a `vocabulary.join`, which Task 6 scopes. **If snapshots change here, stop:** it means a guidance block is interpolating the full vocabulary somewhere Task 2 did not account for.

Note: `RAILS_CONCEPTS.size` goes 20 → 25. Any existing example asserting a vocabulary size will need updating.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add the data-modeling vocabulary and per-language schema artifact

Five concepts folded into both language vocabularies — no new bucket,
since ConceptBucket dispatches on section key and this mode's key is
still code_review. One shared list rather than two, because the Prisma
artifact is relational and every entry means the same in both languages.

schema_artifact mirrors test_framework: present for the two real
languages, absent for the pseudo-language buckets. Nothing reads either
yet."
```

---

### Task 6: Roll the mode and render it

The feature. `DailyPlan` rolls it, `Result` carries it, `CodeReview` renders it, `vocabulary_for` scopes it.

**Files:**
- Modify: `app/services/daily_plan.rb`
- Modify: `app/services/problem_set_ingest.rb`
- Modify: `app/models/exercise_section/code_review.rb`
- Modify: `app/services/ai_service.rb`
- Modify: `spec/services/daily_plan_spec.rb`, `spec/services/problem_set_ingest_spec.rb`, `spec/models/exercise_section_spec.rb`, `spec/services/generation_prompt_characterization_spec.rb`
- Rebaseline: `spec/fixtures/prompt_snapshots/` (16 → 48 files)

**Interfaces:**
- Consumes: `DATA_MODELING_CONCEPTS`, `schema_artifact` (Task 5); `roll_weighted` (Task 3)
- Produces: `DailyPlan::CODE_REVIEW_MODE_WEIGHTS`; `DailyPlan::Result#code_review_mode` (Symbol, one of `:application_code`, `:test_file`, `:schema_review`); `ProblemSetIngest.vocabulary_for(section_key, language, mode: nil)`

- [ ] **Step 1: Write the failing tests**

In `spec/services/daily_plan_spec.rb`:

```ruby
  describe "CODE_REVIEW_MODE_WEIGHTS" do
    it "splits three ways, summing to 1.0" do
      expect(DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys)
        .to eq(%i[application_code test_file schema_review])
      expect(DailyPlan::CODE_REVIEW_MODE_WEIGHTS.values.sum).to be_within(0.001).of(1.0)
    end

    it "reaches every mode" do
      { 0.0 => :application_code, 0.34 => :test_file, 0.67 => :schema_review }.each do |value, expected|
        allow(DailyPlan).to receive(:rand).and_return(value)
        expect(DailyPlan.send(:roll_weighted, DailyPlan::CODE_REVIEW_MODE_WEIGHTS)).to eq(expected)
      end
    end
  end

  describe "#code_review_mode on the plan" do
    let(:user) { User.create!(email: "plan@example.com", name: "Plan") }

    it "is carried on the Result" do
      allow(DailyPlan).to receive(:rand).and_return(0.67)
      expect(DailyPlan.for(user, language: "ruby_rails").code_review_mode).to eq(:schema_review)
    end
  end
```

In `spec/services/problem_set_ingest_spec.rb`, inside `describe ".vocabulary_for"`:

```ruby
    # Ingest validates a persisted set and does not know which mode produced
    # it, so it passes no mode and gets the full list. The narrowing exists to
    # steer generation, not to reject a concept after the fact.
    it "returns the full language vocabulary for code_review with no mode" do
      expect(described_class.vocabulary_for("code_review", "ruby_rails"))
        .to eq(AiService::RAILS_CONCEPTS)
    end

    it "narrows code_review to the data-modeling concepts on a schema-review day" do
      expect(described_class.vocabulary_for("code_review", "ruby_rails", mode: :schema_review))
        .to eq(AiService::DATA_MODELING_CONCEPTS)
    end

    it "excludes the data-modeling concepts on the other two modes" do
      %i[application_code test_file].each do |mode|
        vocabulary = described_class.vocabulary_for("code_review", "ruby_rails", mode: mode)
        expect(vocabulary).not_to include(*AiService::DATA_MODELING_CONCEPTS)
        expect(vocabulary).to include("n_plus_one")
      end
    end

    # pattern keeps the full vocabulary: it is the only section that can host
    # a data-modeling concept on a non-schema day, which keeps a due retention
    # check reachable.
    it "leaves pattern unnarrowed on every mode" do
      %i[application_code test_file schema_review].each do |mode|
        expect(described_class.vocabulary_for("pattern", "ruby_rails", mode: mode))
          .to eq(AiService::RAILS_CONCEPTS)
      end
    end
```

In `spec/models/exercise_section_spec.rb`, under `describe ExerciseSection::CodeReview` in the `.generation_guidance` block:

```ruby
      it "asks for application code by default" do
        text = guidance(described_class, vocabulary: RAILS_VOCAB, mode: :application_code)
        expect(text).to include("realistic Ruby/Rails code")
        expect(text).not_to include("test file")
        expect(text).not_to include("migration")
      end

      it "asks for a test file on a test-file day" do
        text = guidance(described_class, vocabulary: RAILS_VOCAB, mode: :test_file)
        expect(text).to include("test file")
        expect(text).not_to include("migration")
      end

      it "asks for the language's schema artifact on a schema-review day" do
        text = guidance(described_class, vocabulary: AiService::DATA_MODELING_CONCEPTS,
                                          label: "Ruby/Rails", mode: :schema_review)
        expect(text).to include("one planted data-modeling flaw")
        expect(text).to include("missing_index")
        expect(text).not_to include("n_plus_one")
      end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/services/daily_plan_spec.rb spec/services/problem_set_ingest_spec.rb spec/models/exercise_section_spec.rb`
Expected: FAIL — uninitialized `CODE_REVIEW_MODE_WEIGHTS`, unknown keyword `:mode` on `vocabulary_for`, missing mode text.

- [ ] **Step 3: Roll the mode in DailyPlan**

In `app/services/daily_plan.rb`, add beside `FOURTH_SECTION_WEIGHTS`:

```ruby
  # Which content mode code_review takes. Equal thirds, as close as float
  # weights get — application_code keeps a 1% edge rather than the split
  # pretending to be exact.
  #
  # One roll across all three modes, not a probability per mode: the previous
  # arrangement asked the model for "roughly 1 in 4" test-file days in the
  # prompt itself, so nothing decided or recorded the mode and a second
  # "occasional" mode would have compounded with the first unpredictably.
  CODE_REVIEW_MODE_WEIGHTS = {
    application_code: 0.34, test_file: 0.33, schema_review: 0.33
  }.freeze
```

Add `:code_review_mode` to `Result`:

```ruby
  Result = Data.define(:third, :reinforcement, :due_checks, :established,
                        :fourth, :fourth_reinforcement, :fourth_due_checks, :fourth_established,
                        :code_review_mode)
```

In `.for`, add `code_review_mode = roll_weighted(CODE_REVIEW_MODE_WEIGHTS)` beside the other rolls, and pass `code_review_mode: code_review_mode` to `Result.new`.

- [ ] **Step 4: Scope the vocabulary**

In `app/services/problem_set_ingest.rb`, replace `vocabulary_for`:

```ruby
  # The closed vocabulary a section's concept is validated against. Public
  # because the generation prompt has to name the same list this will hold the
  # answer to — AiService#generation_guidance_for calls this, so guidance and
  # validation cannot name different vocabularies.
  #
  # `mode` narrows code_review to its content mode and is passed only by
  # generation. Ingest validates a persisted set and does not know which mode
  # produced it, so it passes none and gets the full list: the narrowing
  # steers what is generated, and is not a reason to reject a concept after
  # the fact.
  #
  # An unrecognized section key — a provider can invent one — falls back to the
  # language's full vocabulary, as it always has.
  def self.vocabulary_for(section_key, language, mode: nil)
    return code_review_vocabulary(language, mode) if mode && section_key == ExerciseSection::CodeReview.key

    case ExerciseSection.find(section_key)&.vocabulary_key
    when :architecture      then AiService::ARCHITECTURE_CONCEPTS
    when :security_concepts then language_config(language)[:security_concepts]
    when :plan_review       then AiService::PLAN_REVIEW_CONCEPTS
    when :ambiguity_hunt    then AiService::AMBIGUITY_HUNT_CONCEPTS
    else                         language_config(language)[:concepts]
    end
  end

  # Only the new mode is scoped. Subtracting the data-modeling concepts from
  # the other two returns exactly the vocabulary they had before those
  # concepts existed, so no existing mode's behavior changes.
  def self.code_review_vocabulary(language, mode)
    full = language_config(language)[:concepts]
    mode == :schema_review ? AiService::DATA_MODELING_CONCEPTS : full - AiService::DATA_MODELING_CONCEPTS
  end
  private_class_method :code_review_vocabulary
```

- [ ] **Step 5: Render the mode**

In `app/models/exercise_section/code_review.rb`, replace `generation_guidance`:

```ruby
  # The only kind with a content mode. `artifact` is the day's language-
  # specific schema artifact (see AiService::LANGUAGE_CONFIG) and is read only
  # on a schema-review day.
  def self.generation_guidance(vocabulary:, label:, mode: nil, artifact: nil)
    <<~GUIDANCE.chomp
      #{content_instruction(label, mode, artifact)}
      - Choose the code_review concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
    GUIDANCE
  end

  def self.content_instruction(label, mode, artifact)
    case mode
    when :test_file
      "- The code_review snippet must be #{label} test code — a realistic test file exhibiting one real test smell, same question shape (\"what's the issue here, and how would you fix it\")."
    when :schema_review
      "- The code_review snippet must be #{artifact}, ~10-15 lines, containing one planted data-modeling flaw. Same question shape as any other code_review (\"what's the issue here, and how would you fix it\") — the engineer reviews the proposed change, not prose about it."
    else
      "- The code_review snippet must be realistic #{label} code — not toy examples."
    end
  end
  private_class_method :content_instruction
```

- [ ] **Step 6: Thread it through AiService**

In `app/services/ai_service.rb`, change `generation_guidance_for` to accept and forward the mode:

```ruby
  def generation_guidance_for(kind, language, mode: nil)
    kind.generation_guidance(
      **{ vocabulary: ProblemSetIngest.vocabulary_for(kind.key, language, mode: mode),
          label:      config_for(language)[:label],
          mode:       mode }.merge(
            kind == ExerciseSection::CodeReview ? { artifact: config_for(language)[:schema_artifact] } : {}
          )
    )
  end
```

In `build_exercise_prompt`, add `code_review_mode: :application_code` to the keyword list (defaulted so existing direct callers and specs keep working), change the code_review guidance line to:

```ruby
    code_review_guidance = generation_guidance_for(ExerciseSection::CodeReview, language, mode: code_review_mode)
```

and **delete** the now-dead `test_file_clause` assignment and the `#{test_file_clause}` interpolation, changing the prompt body line to:

```
      - Rotate between topics across sessions — avoid the same pattern two days in a row.
```

(that is, remove the whole `- The code_review snippet must be realistic #{label} code — not toy examples.#{test_file_clause}` line — it now comes from the guidance).

In `generate_exercise`, pass `code_review_mode: plan.code_review_mode` into `build_exercise_prompt`, and add it to the diagnostics payload's `requested:` hash:

```ruby
      requested: {
        skill_level: user.skill_level,
        code_review_mode: plan.code_review_mode,
        reinforcement: plan.reinforcement,
        # ...unchanged...
      },
```

- [ ] **Step 7: Add the mode axis to the characterization spec**

In `spec/services/generation_prompt_characterization_spec.rb`, change `render` and `snapshot_path` to take a mode, and nest a third loop:

```ruby
  def render(language, third, fourth, mode)
    service.send(
      :build_exercise_prompt, user, language,
      third: third, fourth: fourth, code_review_mode: mode,
      reinforcement: [], due_checks: [], established: [], history: [],
      fourth_reinforcement: [], fourth_due_checks: [], fourth_established: []
    )
  end

  def snapshot_path(language, third, fourth, mode)
    SNAPSHOT_DIR.join("#{language}__#{third}__#{fourth}__#{mode}.txt")
  end
```

Wrap the existing `context` in `DailyPlan::CODE_REVIEW_MODE_WEIGHTS.each_key do |mode|`, add `/ #{mode}` to the context description, thread `mode` through both examples, and update the orphan-check `expected` list to include the mode in each filename.

- [ ] **Step 8: Delete the stale snapshots and rebaseline (rebaseline 2 of 2)**

```bash
git rm -q spec/fixtures/prompt_snapshots/*.txt
UPDATE_PROMPT_SNAPSHOTS=1 bundle exec rspec spec/services/generation_prompt_characterization_spec.rb
bundle exec rspec spec/services/generation_prompt_characterization_spec.rb
ls spec/fixtures/prompt_snapshots/ | wc -l
```

Expected: 48 files, spec passes on the second run.

Confirm the mode actually varies:

```bash
grep -h "code_review snippet must be" spec/fixtures/prompt_snapshots/ruby_rails__challenge__plan_review__*.txt
```

Expected: three different lines — realistic code, test code, a Rails migration.

- [ ] **Step 9: Run the full suite and fix fallout**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
Expected: PASS. Likely fallout: `daily_plan_spec` examples constructing `Result` positionally, and `ai_service_spec` examples asserting the old test-file clause wording.

- [ ] **Step 10: Lint and commit**

```bash
bundle exec rubocop app/ spec/
git add -A
git commit -m "Roll a code_review content mode and render it

code_review gains a third content mode: a proposed migration carrying one
planted data-modeling flaw. Same section key, same question shape, same
grading pipeline — only the snippet's subject changes, so no view, no
schema fragment, and no section kind changes.

Mode selection moves from the prompt into DailyPlan. It was previously a
sentence asking the model for 'roughly 1 in 4' test-file days: nothing
decided it, nothing recorded it, and a second occasional mode would have
compounded with the first unpredictably. One weighted roll now decides
it, Result carries it, and it lands in the difficulty-diagnostics payload
so 'do schema days grade differently?' is answerable from logs.

Only the new mode is vocabulary-scoped. Subtracting the data-modeling
concepts from the other two returns exactly the list they had before,
so no existing mode's behavior changes. Ingest passes no mode and gets
the full list: the narrowing steers generation and is not a reason to
reject a concept after the fact.

Snapshots go 16 to 48 — mode is a fourth axis, and the cross-product is
what catches a regression that only shows in one pairing."
```

---

### Task 7: Teach retention annotation about the mode

The one interaction reaching beyond code_review's own generation branch.

**Files:**
- Modify: `app/services/ai_service.rb` (`annotate_retention_concept`, its caller)
- Modify: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: `DATA_MODELING_CONCEPTS` (Task 5); `code_review_mode` (Task 6)
- Produces: nothing downstream

- [ ] **Step 1: Write the failing tests**

In `spec/services/ai_service_spec.rb`, in the `retention prompt block` describe:

```ruby
    def annotation(concept, language:, third:, mode:)
      cm = ConceptMastery.create!(user: user, concept: concept, language: language,
                                  tier: :standard, next_retention_check_on: Date.current,
                                  retention_interval_days: 7)
      service.send(:annotate_retention_concept, cm, third, mode)
    end

    it "offers code_review for a data-modeling concept only on a schema-review day" do
      expect(annotation("missing_index", language: "ruby_rails", third: :challenge, mode: :schema_review))
        .to eq("missing_index (code_review, pattern, or challenge)")
      expect(annotation("missing_index", language: "ruby_rails", third: :challenge, mode: :application_code))
        .to eq("missing_index (pattern or challenge)")
    end

    it "withholds code_review from an ordinary concept on a schema-review day" do
      expect(annotation("n_plus_one", language: "ruby_rails", third: :challenge, mode: :schema_review))
        .to eq("n_plus_one (pattern or challenge)")
    end

    it "is unchanged for an ordinary concept on a non-schema day" do
      expect(annotation("n_plus_one", language: "ruby_rails", third: :challenge, mode: :application_code))
        .to eq("n_plus_one (code_review, pattern, or challenge)")
      expect(annotation("n_plus_one", language: "ruby_rails", third: :architecture, mode: :application_code))
        .to eq("n_plus_one (code_review or pattern)")
      expect(annotation("memoization", language: "ruby_rails", third: :security_review, mode: :application_code))
        .to eq("memoization (code_review or pattern)")
      expect(annotation("sql_injection_prevention", language: "ruby_rails", third: :security_review, mode: :application_code))
        .to eq("sql_injection_prevention (code_review, pattern, or security_review)")
    end

    it "still routes an architecture-bucket concept to its own section" do
      expect(annotation("service_boundaries", language: "architecture", third: :architecture, mode: :application_code))
        .to eq("service_boundaries (architecture section)")
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "retention prompt block"`
Expected: FAIL — `ArgumentError: wrong number of arguments (given 3, expected 2)`.

- [ ] **Step 3: Rewrite the annotation**

In `app/services/ai_service.rb`, replace `annotate_retention_concept` with:

```ruby
  # A due retention concept's `language` bucket names which vocabulary it was
  # validated against, but not which section(s) that vocabulary is legal in
  # today — without this the model has no way to know an architecture-vocabulary
  # concept can't go in code_review, guesses wrong, and ingest rewrites a
  # correctly-honored check into a false "miss".
  #
  # code_review's legal concepts now depend on the day's content mode as well:
  # a schema-review day hosts only data-modeling concepts, and every other day
  # hosts only the rest. pattern and the language-vocabulary thirds are
  # unscoped, which is what keeps a due data-modeling concept reachable on a
  # non-schema day.
  def annotate_retention_concept(cm, third, code_review_mode)
    return "#{cm.concept} (architecture section)" if cm.language == "architecture"

    hosts = []
    hosts << "code_review" if data_modeling?(cm.concept) == (code_review_mode == :schema_review)
    hosts << "pattern"
    hosts << third.to_s if third_can_host?(cm, third)

    "#{cm.concept} (#{hosts.to_sentence(two_words_connector: ' or ', last_word_connector: ', or ')})"
  end

  def data_modeling?(concept)
    DATA_MODELING_CONCEPTS.include?(concept)
  end

  # An architecture third draws from its own vocabulary, and a security_review
  # third from a restricted subset, so neither can host an arbitrary
  # language-bucket concept.
  def third_can_host?(cm, third)
    case third
    when :architecture    then false
    when :security_review then config_for(cm.language)[:security_concepts].include?(cm.concept)
    else                       true
    end
  end
```

- [ ] **Step 4: Update the caller**

In `build_exercise_prompt`'s `retention_block`, change:

```ruby
          Retention checks due today: #{due_checks.map { |cm| annotate_retention_concept(cm, third) }.join(', ')}
```

to:

```ruby
          Retention checks due today: #{due_checks.map { |cm| annotate_retention_concept(cm, third, code_review_mode) }.join(', ')}
```

- [ ] **Step 5: Comment the slot approximation**

In `app/services/daily_plan.rb`, extend the comment above `slots` in `.for` so the approximation cannot later be mistaken for exactness:

```ruby
    # ...existing comment...
    #
    # This 3 is approximate, deliberately. On a schema-review day code_review
    # hosts only data-modeling concepts, so an ordinary concept has two hosts
    # rather than three. Left approximate because the arithmetic is advisory
    # end to end — nothing verifies placement, and over-requesting by one costs
    # a concept the model could not have placed anyway. Making it mode-aware
    # would reopen this state machine, whose correctness rests on structural
    # separation rather than on arguments about interacting conditions.
    # AiService#log_retention already records offered-versus-honored per
    # bucket, so if this matters it will show up there first.
    slots         = 3 - reinforcement.first(3).size
```

- [ ] **Step 6: Run the full suite**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
Expected: PASS. Snapshots must be untouched — the characterization spec renders with `due_checks: []`, so no retention block appears in any snapshot. Verify with `git status spec/fixtures/prompt_snapshots/`.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec rubocop app/ spec/
git add -A
git commit -m "Make retention annotation aware of the code_review mode

The one place the mode roll reaches beyond code_review's own generation
branch. A due concept's annotation names which sections may host it; with
code_review's vocabulary now depending on the day's mode, the annotation
has to say so or the model guesses wrong and ingest rewrites a
correctly-honored check into a false miss.

The if-chain becomes a host list, which the new axis would otherwise have
turned into four nested conditions.

DailyPlan's slot arithmetic still assumes three hosts. Left approximate on
purpose, and now commented at the point of the read: it is advisory end to
end, and making it exact would reopen the subtlest state machine in the
app for a gain log_retention can already measure."
```

---

### Task 8: Remove the planning docs and open the PR

**Files:**
- Delete: `docs/superpowers/specs/2026-08-12-schema-review-mode-design.md`
- Delete: `docs/superpowers/plans/2026-08-12-schema-review-mode.md`

- [ ] **Step 1: Confirm the whole suite and lint are green**

```bash
bundle exec rspec --exclude-pattern "system/**/*_spec.rb"
bundle exec rubocop app/ spec/
```

Expected: 0 failures, 0 offenses.

- [ ] **Step 2: Run the system specs**

Run: `bundle exec rspec spec/system/`
Expected: PASS. Nothing here touches views, but `dashboard_generation_spec` exercises real generation through `FakeService`.

- [ ] **Step 3: Delete both planning docs**

Read this plan's remaining steps first — deleting it removes your instructions.

```bash
git rm docs/superpowers/specs/2026-08-12-schema-review-mode-design.md
git rm docs/superpowers/plans/2026-08-12-schema-review-mode.md
git commit -m "Remove the planning docs from the branch

Spec and plan stay out of PRs; both were committed so they could be read
while the work was in progress. Added and removed on the same branch, so
the PR diff carries neither."
```

- [ ] **Step 4: Verify the branch state before pushing**

```bash
git status --short --branch
git log --oneline main..HEAD
grep -rn "docs/superpowers/specs/" app/ || echo "no dangling references"
```

Expected: on `feat/schema-review-mode`, eleven commits (three planning-doc commits plus eight of work), a diff against `main` containing no files under `docs/superpowers/`, and no dangling references. **If `git status` prints `## HEAD (no branch)`, stop and recover** — `gh` has detached HEAD in this repo before.

- [ ] **Step 5: Push and open the PR**

```bash
git push -u origin feat/schema-review-mode
```

Open the PR against `main`. The body should lead with the two premises the investigation corrected (no existing test-file roll; candidate 1 never covered `code_review`), state that #81 is closed by dissolution rather than patch, and flag the two deliberate behavior changes: equal third-slot weights reversing the architecture bias, and schema days scoping code_review's vocabulary.

---

## Self-Review

**Spec coverage:** Mode selection in `DailyPlan` → Task 6. `schema_artifact` per language → Task 5. Five concepts with the rename → Task 5. Mode-scoped vocabulary → Task 6. `CodeReview`/`Pattern` guidance and #81 → Task 2. Retention annotation → Task 7. Slot approximation comment → Task 7 Step 5. Equal weights → Task 4. `roll_weighted` → Task 3. Snapshots at 48, rebaselined twice → Tasks 2 and 6. Dangling comments → Task 1. Spec-doc deletion → Task 8. No gaps.

**Placeholder scan:** No TBD/TODO. Every code step carries the code.

**Type consistency:** `code_review_mode` is a Symbol everywhere. `generation_guidance` is `(vocabulary:, label:, mode: nil)` from Task 2 on, with `artifact:` added for `CodeReview` only in Task 6 — Task 6 Step 6's caller passes `artifact:` to `CodeReview` alone, matching. `vocabulary_for` gains `mode:` in Task 6 and every Task 2 call site omits it, which the default covers.
