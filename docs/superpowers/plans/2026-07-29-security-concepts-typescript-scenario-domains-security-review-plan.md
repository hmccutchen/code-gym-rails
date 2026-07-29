# Security concepts, TypeScript-flavored JS, scenario domains, Security Review — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four independent pieces to the exercise-generation system: security-focused tracked concepts, TypeScript-flavored JS concepts, curated scenario-domain grounding for the prompt, and a new "Security Review" third-section question type that reuses the new security concepts.

**Architecture:** All four changes are additive extensions to `AiService` (prompt/schema builder), with Change 4 also touching `DailyExercise` (new accessor + discriminator helper), `ResponsesController`, `User#recent_performance`, and three view partials. No migrations — every touched column is jsonb.

**Tech Stack:** Ruby on Rails 8, RSpec, PostgreSQL (jsonb columns), ERB views, vanilla JS (no Stimulus/Turbo JS on this layout).

## Global Constraints

- No migrations anywhere in this plan — every new key lives in an existing jsonb column (`problem_set`, `ai_review`, `concept_tags`, `answers`, `section_ratings`).
- No changes to: magic-link auth, Resend/SMTP, timezone handling, `ConceptReference`'s generation mechanism, the suggested-concepts admin flow, `ConceptMastery`'s tier-transition logic, or `User::LANGUAGES`/`DailyExercise::LANGUAGES`.
- Each of the 4 changes in the spec ships as its own commit (or short run of commits) with its own passing tests before the next begins — task order below follows that sequencing.
- Spec: `docs/superpowers/specs/2026-07-29-security-concepts-typescript-scenario-domains-security-review-design.md`.
- Run the full suite (`bundle exec rspec`) after each task's own spec file passes, to catch cross-file breakage early (several files share `AiService` constants).

---

### Task 1: Security concepts — add to RAILS_CONCEPTS / JS_CONCEPTS

**Files:**
- Modify: `app/services/ai_service.rb:23-35`
- Test: `spec/services/ai_service_spec.rb:168-182`

**Interfaces:**
- Produces: `AiService::RAILS_CONCEPTS` (18 entries, was 16), `AiService::JS_CONCEPTS` (16 entries, was 14) — both still frozen `Array<String>`, consumed everywhere by name already (no new interface).

- [ ] **Step 1: Update the two existing vocabulary-size specs to fail against the new counts**

Replace the `"RAILS_CONCEPTS"` and `"JS_CONCEPTS"` describe blocks (lines 168-182) with:

```ruby
  describe "RAILS_CONCEPTS" do
    it "is a frozen 18-entry vocabulary" do
      expect(AiService::RAILS_CONCEPTS.size).to eq(18)
      expect(AiService::RAILS_CONCEPTS).to be_frozen
      expect(AiService::RAILS_CONCEPTS).to include("n_plus_one", "transaction_safety", "error_handling")
    end

    it "includes the two Rails security concepts chosen for real depth" do
      expect(AiService::RAILS_CONCEPTS).to include("mass_assignment_protection", "sql_injection_prevention")
    end

    it "excludes secure_secrets_handling and dependency_vulnerability_management as poor fits for this app's format" do
      expect(AiService::RAILS_CONCEPTS).not_to include("secure_secrets_handling", "dependency_vulnerability_management")
    end
  end

  describe "JS_CONCEPTS" do
    it "is a frozen 16-entry vocabulary" do
      expect(AiService::JS_CONCEPTS.size).to eq(16)
      expect(AiService::JS_CONCEPTS).to be_frozen
      expect(AiService::JS_CONCEPTS).to include("closures", "prototype_chain", "hooks_dependencies")
    end

    it "includes the two JS security concepts chosen for real depth" do
      expect(AiService::JS_CONCEPTS).to include("xss_prevention", "insecure_client_storage")
    end
  end
```

- [ ] **Step 2: Run the new specs to verify they fail**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "RAILS_CONCEPTS" -e "JS_CONCEPTS"`
Expected: FAIL — size mismatches (16≠18, 14≠16) and missing-inclusion failures.

- [ ] **Step 3: Add the four concepts and the exclusion comment**

In `app/services/ai_service.rb`, replace lines 19-35 with:

```ruby
  # Fixed concept vocabularies, one per generation language. Embedded in the
  # generation prompt; anything a provider returns outside the active list is
  # normalized to "other" so per-user concept history stays aggregatable.
  # Kept closed rather than AI-extensible so history stays clean.
  #
  # Security concepts are deliberately selective: the mastery-tier system
  # (Standard/Reduced/Paused, easing/reinforcing over time) only pays off for
  # concepts with real depth — room to be approached multiple ways, room to
  # get harder or easier. Two proposed security items were cut for lacking
  # that depth: `secure_secrets_handling` is essentially one rule ("don't
  # hardcode credentials") with no harder version to graduate toward, and
  # `dependency_vulnerability_management` is a process/tooling habit (running
  # an audit tool, reviewing a Dependabot PR) that no code snippet can test —
  # the wrong shape for this app's format entirely.
  RAILS_CONCEPTS = %w[
    n_plus_one transaction_safety memoization service_objects scope_chaining
    idempotency authorization background_jobs caching validations
    callbacks_vs_service query_objects policy_objects indexing concurrency
    error_handling mass_assignment_protection sql_injection_prevention
  ].freeze

  JS_CONCEPTS = %w[
    callback_hell promise_chaining closures prototype_chain event_loop_blocking
    this_binding array_mutation_pitfalls debouncing_throttling closures_in_loops
    memory_leaks_listeners hooks_dependencies component_re_renders state_lifting
    controlled_vs_uncontrolled xss_prevention insecure_client_storage
  ].freeze
```

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS (all examples, including the two vocabulary describe blocks and every other spec in the file that references vocabulary size only implicitly — none do besides these).

- [ ] **Step 5: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Add mass_assignment_protection/sql_injection_prevention and xss_prevention/insecure_client_storage security concepts"
```

---

### Task 2: TypeScript-flavored concepts folded into JS_CONCEPTS

**Files:**
- Modify: `app/services/ai_service.rb` (JS_CONCEPTS, new `TYPESCRIPT_FLAVORED_CONCEPTS` constant, `build_exercise_prompt`)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: `AiService::JS_CONCEPTS` from Task 1.
- Produces: `AiService::TYPESCRIPT_FLAVORED_CONCEPTS` (frozen `Array<String>`, 4 entries, subset of `JS_CONCEPTS`).

- [ ] **Step 1: Write the failing vocabulary tests**

Add a new describe block right after `"JS_CONCEPTS"` in `spec/services/ai_service_spec.rb`:

```ruby
  describe "TYPESCRIPT_FLAVORED_CONCEPTS" do
    it "is a frozen 4-entry subset of JS_CONCEPTS" do
      expect(AiService::TYPESCRIPT_FLAVORED_CONCEPTS.size).to eq(4)
      expect(AiService::TYPESCRIPT_FLAVORED_CONCEPTS).to be_frozen
      expect(AiService::TYPESCRIPT_FLAVORED_CONCEPTS - AiService::JS_CONCEPTS).to be_empty
      expect(AiService::TYPESCRIPT_FLAVORED_CONCEPTS).to contain_exactly(
        "generics", "type_guards_narrowing", "union_intersection_types", "mapped_conditional_types"
      )
    end
  end
```

Update the `"JS_CONCEPTS"` size test from Task 1 to expect 20:

```ruby
    it "is a frozen 20-entry vocabulary" do
      expect(AiService::JS_CONCEPTS.size).to eq(20)
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "TYPESCRIPT_FLAVORED_CONCEPTS" -e "JS_CONCEPTS"`
Expected: FAIL — `TYPESCRIPT_FLAVORED_CONCEPTS` undefined; size 16≠20.

- [ ] **Step 3: Add the constant and extend JS_CONCEPTS**

In `app/services/ai_service.rb`, change the `JS_CONCEPTS` array to:

```ruby
  JS_CONCEPTS = %w[
    callback_hell promise_chaining closures prototype_chain event_loop_blocking
    this_binding array_mutation_pitfalls debouncing_throttling closures_in_loops
    memory_leaks_listeners hooks_dependencies component_re_renders state_lifting
    controlled_vs_uncontrolled xss_prevention insecure_client_storage
    generics type_guards_narrowing union_intersection_types mapped_conditional_types
  ].freeze

  # Subset of JS_CONCEPTS that reflects real TypeScript usage rather than a
  # separate language mode: no new generation language, no schema change.
  # When one of these is the section's tagged concept, build_exercise_prompt
  # instructs real TS syntax/annotations for that section only — every other
  # JS_CONCEPTS entry stays plain JS, matching actual day-to-day variety.
  TYPESCRIPT_FLAVORED_CONCEPTS = %w[
    generics type_guards_narrowing union_intersection_types mapped_conditional_types
  ].freeze
```

- [ ] **Step 4: Run to verify the vocabulary tests pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "TYPESCRIPT_FLAVORED_CONCEPTS" -e "JS_CONCEPTS"`
Expected: PASS

- [ ] **Step 5: Write the failing prompt-instruction tests**

Add to the `"#build_exercise_prompt"` describe block in `spec/services/ai_service_spec.rb`:

```ruby
    it "includes TypeScript-syntax guidance keyed off the TS-flavored concepts when language is javascript" do
      prompt = service.send(:build_exercise_prompt, user, "javascript")
      expect(prompt).to include("TypeScript syntax")
      expect(prompt).to include(AiService::TYPESCRIPT_FLAVORED_CONCEPTS.join(", "))
    end

    it "omits TypeScript-syntax guidance for ruby_rails" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails")
      expect(prompt).not_to include("TypeScript syntax")
    end
```

- [ ] **Step 6: Run to verify failure**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "TypeScript-syntax guidance"`
Expected: FAIL — no such text in the prompt yet.

- [ ] **Step 7: Add the conditional instruction to `build_exercise_prompt`**

In `app/services/ai_service.rb`, inside `build_exercise_prompt` (around line 494, right before the `config`/`label`/`focus`/`concepts` local-variable block), add:

```ruby
    ts_guidance =
      if language == "javascript"
        "- If a section's tagged concept is one of #{TYPESCRIPT_FLAVORED_CONCEPTS.join(", ")}, write that section's code using real TypeScript syntax and type annotations. Every other section stays plain JavaScript — do not switch the whole set to TypeScript just because one section calls for it.\n"
      else
        ""
      end
```

Then splice `#{ts_guidance}` into the returned `PROMPT` heredoc, immediately after the existing line:

```
      - Vary the concrete business-domain scenario and code structure across sessions, not just the concept — do not reuse the class/method names or narrative framing shown in the "framings:" notes above.
```

so that line is followed by `#{ts_guidance}` on its own line (no leading `-`, since `ts_guidance` already includes the bullet dash or is blank).

- [ ] **Step 8: Run to verify the prompt tests pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS (full file)

- [ ] **Step 9: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Fold TypeScript-flavored concepts into JS_CONCEPTS with prompt-level TS-syntax guidance"
```

---

### Task 3: Scenario-domain grounding (SCENARIO_DOMAINS)

**Files:**
- Modify: `app/services/ai_service.rb` (new `SCENARIO_DOMAINS` constant, `build_exercise_prompt`)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Produces: `AiService::SCENARIO_DOMAINS` (frozen `Array<String>`, 9 entries) — prompt-text only, never touches `concept_vocabulary_for` or any bucket.

- [ ] **Step 1: Write the failing constant test**

Add a new describe block after `"ARCHITECTURE_CONCEPTS"` in `spec/services/ai_service_spec.rb`:

```ruby
  describe "SCENARIO_DOMAINS" do
    it "is a frozen list of scenario flavors, including a rare legacy-GraphQL entry" do
      expect(AiService::SCENARIO_DOMAINS).to be_frozen
      expect(AiService::SCENARIO_DOMAINS).to include(
        "background_job_processing", "api_versioning_and_deprecation",
        "activerecord_query_construction", "component_state_management",
        "legacy_graphql_maintenance"
      )
    end

    it "is never mixed into any tracked concept vocabulary" do
      expect(AiService::SCENARIO_DOMAINS & AiService::RAILS_CONCEPTS).to be_empty
      expect(AiService::SCENARIO_DOMAINS & AiService::JS_CONCEPTS).to be_empty
      expect(AiService::SCENARIO_DOMAINS & AiService::ARCHITECTURE_CONCEPTS).to be_empty
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "SCENARIO_DOMAINS"`
Expected: FAIL — `AiService::SCENARIO_DOMAINS` undefined.

- [ ] **Step 3: Add the constant**

In `app/services/ai_service.rb`, add after the `ARCHITECTURE_CONCEPTS` constant (after line 46):

```ruby
  # Curated, real, job-adjacent scenario flavors for the "scenario" field's
  # business-domain framing — prompt-level grounding only, to keep generated
  # scenarios feeling like real engineering work rather than generic SaaS
  # examples. Never concept-tagged, never fed into concept_vocabulary_for or
  # any mastery-loop bucket. `legacy_graphql_maintenance` is scenario dressing
  # only, for occasional legacy-app relevance — see build_exercise_prompt's
  # explicit low-frequency instruction. It must never appear as a "concept"
  # value.
  SCENARIO_DOMAINS = %w[
    background_job_processing api_versioning_and_deprecation
    activerecord_query_construction component_state_management
    data_export_and_reporting webhook_delivery rate_limiting
    multi_tenant_data_isolation legacy_graphql_maintenance
  ].freeze
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "SCENARIO_DOMAINS"`
Expected: PASS

- [ ] **Step 5: Write the failing prompt-instruction test**

Add to the `"#build_exercise_prompt"` describe block:

```ruby
    it "prefers drawing scenarios from SCENARIO_DOMAINS, with legacy GraphQL framed as rare and concept-free" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("background job processing")
      expect(prompt).to include("activerecord query construction")
      expect(prompt.downcase).to include("legacy graphql")
      expect(prompt).to match(/1 in every 8-10/)
      expect(prompt.downcase).to include("never as the tagged concept")
    end
```

- [ ] **Step 6: Run to verify failure**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "prefers drawing scenarios"`
Expected: FAIL

- [ ] **Step 7: Add the scenario-domain instruction to `build_exercise_prompt`**

In `app/services/ai_service.rb`, in the same local-variable block added in Task 2 Step 7, add:

```ruby
    scenario_domain_list = (SCENARIO_DOMAINS - %w[legacy_graphql_maintenance]).map { |d| d.tr("_", " ") }.join(", ")
```

Then splice a new bullet into the `PROMPT` heredoc, directly after the "Vary the concrete business-domain scenario..." line (and its immediately-following `#{ts_guidance}` line from Task 2):

```
      - Prefer drawing each section's business-domain scenario from real, job-adjacent flavors like: #{scenario_domain_list}. Use a legacy GraphQL maintenance scenario (e.g. "a legacy GraphQL layer needs a fix") only rarely — at most roughly 1 in every 8-10 sessions — purely as scenario framing, never as the tagged concept.
```

- [ ] **Step 8: Run to verify the prompt test passes**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS (full file)

- [ ] **Step 9: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Add SCENARIO_DOMAINS for job-adjacent scenario grounding, with rare legacy-GraphQL framing"
```

---

### Task 4: Security Review rotation (3-way roll + retention annotation fix)

**Files:**
- Modify: `app/services/ai_service.rb` (`roll_third_section` → `THIRD_SECTION_WEIGHTS`; `annotate_retention_concept`)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Produces: `AiService::THIRD_SECTION_WEIGHTS` (frozen `Hash{Symbol=>Float}`); `#roll_third_section` now returns `:architecture` / `:security_review` / `:challenge` (was `:architecture` / `:challenge`).
- Consumed by: Task 5 (`exercise_schema_for`), Task 6 (`build_exercise_prompt`'s `third_guidance`), Task 7 (`build_review_prompt` via `exercise.third_key`).

- [ ] **Step 1: Replace the existing `#roll_third_section` spec with the 3-way version**

Replace the existing `describe "#roll_third_section"` block (lines 130-143) in `spec/services/ai_service_spec.rb` with:

```ruby
  describe "#roll_third_section" do
    it "returns :architecture below 0.50, :security_review from 0.50 up to 0.75, :challenge from 0.75 up" do
      allow(service).to receive(:rand).and_return(0.10)
      expect(service.send(:roll_third_section)).to eq(:architecture)

      allow(service).to receive(:rand).and_return(0.49)
      expect(service.send(:roll_third_section)).to eq(:architecture)

      allow(service).to receive(:rand).and_return(0.50)
      expect(service.send(:roll_third_section)).to eq(:security_review)

      allow(service).to receive(:rand).and_return(0.74)
      expect(service.send(:roll_third_section)).to eq(:security_review)

      allow(service).to receive(:rand).and_return(0.75)
      expect(service.send(:roll_third_section)).to eq(:challenge)

      allow(service).to receive(:rand).and_return(0.99)
      expect(service.send(:roll_third_section)).to eq(:challenge)
    end
  end
```

Also add a new retention-annotation test to the `"retention prompt block"` describe block (after the existing "annotates a language-bucket concept's legal sections for the architecture third" test, around line 417):

```ruby
    it "annotates a language-bucket concept's legal sections for the security_review third" do
      cm = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                          mastered_at: 1.month.ago, retention_interval_days: 7,
                                          next_retention_check_on: Date.current - 2)
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :security_review,
                            reinforcement: [], due_checks: [ cm ])

      expect(prompt).to include("Retention checks due today: memoization (code_review, pattern, or security_review)")
    end
```

- [ ] **Step 2: Run to verify both fail**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "roll_third_section" -e "security_review third"`
Expected: FAIL — old 60/40 boundary logic still in place; annotation still says "challenge" unconditionally in the else branch.

- [ ] **Step 3: Implement the 3-way weighted roll**

In `app/services/ai_service.rb`, replace the `roll_third_section` method and its preceding comment (lines 261-267) with:

```ruby
  # Which third section this set gets. Named, tunable weights rather than a
  # bare literal: architecture-reasoning most of the time, a security-review
  # snippet a quarter of the time, a traditional coding challenge the rest.
  # Extracted so tests can stub it — never assert on real randomness. The
  # chosen kind is not tracked separately; the persisted third key
  # (problem_set["architecture"/"security_review"/"challenge"]) is the record.
  THIRD_SECTION_WEIGHTS = { architecture: 0.50, security_review: 0.25, challenge: 0.25 }.freeze

  def roll_third_section
    r = rand
    return :architecture    if r < THIRD_SECTION_WEIGHTS[:architecture]
    return :security_review if r < THIRD_SECTION_WEIGHTS[:architecture] + THIRD_SECTION_WEIGHTS[:security_review]
    :challenge
  end
```

- [ ] **Step 4: Fix `annotate_retention_concept`'s else-branch to name the actual third kind**

Replace the method (lines 328-341) with:

```ruby
  # A due retention concept's `language` bucket names which vocabulary it was
  # validated against, but not which section(s) that vocabulary is legal in
  # today — without this the model has no way to know an architecture-vocabulary
  # concept can't go in code_review, guesses wrong, and normalize_concepts
  # rewrites a correctly-honored check into a false "miss". The else branch
  # names `third` itself (not a hardcoded "challenge") because a language-
  # bucket concept is equally legal in whichever non-architecture third
  # section today actually has — challenge or security_review.
  def annotate_retention_concept(cm, third)
    if cm.language == "architecture"
      "#{cm.concept} (architecture section)"
    elsif third == :architecture
      "#{cm.concept} (code_review or pattern)"
    else
      "#{cm.concept} (code_review, pattern, or #{third})"
    end
  end
```

- [ ] **Step 5: Run the full spec file to verify everything passes**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Roll a 3-way weighted third section (architecture/security_review/challenge)"
```

---

### Task 5: Security Review schema (`exercise_schema_for`)

**Files:**
- Modify: `app/services/ai_service.rb:389-449` (`exercise_schema_for`)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: `label` (from `config_for(language)[:label]`), `glossary_field` (already-built string), same as the existing architecture/challenge branches.
- Produces: `exercise_schema_for(language, third: :security_review)` returns a JSON schema string with a `"security_review"` top-level key shaped `{title, question, snippet, teaching_note, concept, glossary, reference: {tagline, explanation, code_example, senior_lens}}`.

- [ ] **Step 1: Write the failing schema tests**

Add to the `"#exercise_schema_for"` describe block in `spec/services/ai_service_spec.rb` (after the existing architecture-schema tests, around line 90):

```ruby
    it "swaps in the security_review block with a vulnerable snippet and a mitigation question when third: :security_review" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :security_review)
      expect(schema).to include("\"security_review\"")
      expect(schema).to include("snippet")
      expect(schema.downcase).to include("mitigate")
      expect(schema).not_to include("\"architecture\"")
      expect(schema).not_to include("\"challenge\"")
    end

    it "gives security_review's reference the same shape as a normal concept reference, not architecture's tradeoffs-plural shape" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :security_review)
      security_review = JSON.parse(schema)["security_review"]
      expect(security_review["reference"].keys).to contain_exactly("tagline", "explanation", "code_example", "senior_lens")
    end

    it "does not ask for a diagram on a security_review third" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :security_review)
      expect(schema).not_to match(/mermaid/i)
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "security_review"`
Expected: FAIL — `third: :security_review` currently falls into the `else` (challenge) branch of the existing `if/else`.

- [ ] **Step 3: Convert the `if/else` to a `case` and add the security_review branch**

In `app/services/ai_service.rb`, replace the `third_section =` assignment inside `exercise_schema_for` (lines 393-425) with:

```ruby
    third_section =
      case third
      when :architecture
        <<~ARCH.chomp
          "architecture": {
              "title":     "string — short name for the decision",
              "scenario":  "string — 2-3 sentences, ~50 words max. Exactly 2-3 concrete constraints total, no more",
              "question":  "string — ONE sentence asking for a decision + justification",
              "options":   ["string — a viable approach", "string — another viable approach", "string — an optional third approach (omit for 2)"],
              "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
              "concept": "string — exactly one concept from the architecture vocabulary",
              #{glossary_field},
              "reference": {
                "tagline":     "string — bold one-liner",
                "explanation": "string — 2-3 sentences",
                "tradeoffs":   ["string — a tradeoff", "string — a tradeoff", "string — a tradeoff"],
                "senior_lens": "string — how a senior frames the decision",
                "diagram":     "string — Mermaid source visualizing the decision, or an empty string if no diagram would help"
              }
            }
        ARCH
      when :security_review
        <<~SEC.chomp
          "security_review": {
              "title":        "string",
              "question":     "string — what security vulnerability exists here, and how would you mitigate it",
              "snippet":      "string — #{label} code, ~10-15 lines, containing one real, exploitable vulnerability",
              "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
              "concept": "string — exactly one concept from the provided vocabulary",
              #{glossary_field},
              "reference": {
                "tagline":      "string — bold one-liner",
                "explanation":  "string — 2-3 sentences",
                "code_example": "string — annotated #{label} code, ~15 lines",
                "senior_lens":  "string — when to reach for it / tradeoffs"
              }
            }
        SEC
      else
        <<~CH.chomp
          "challenge": {
              "title":        "string",
              "question":     "string — what to implement",
              "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
              "starter_code": "string — optional skeleton (empty string if none)",
              "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
              "concept": "string — exactly one concept from the provided vocabulary",
              #{glossary_field}
            }
        CH
      end
```

- [ ] **Step 4: Run to verify all schema tests pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "#exercise_schema_for"`
Expected: PASS

- [ ] **Step 5: Run the full file**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Add security_review schema branch to exercise_schema_for"
```

---

### Task 6: Security Review generation guidance (`build_exercise_prompt`)

**Files:**
- Modify: `app/services/ai_service.rb:499-518` (`third_guidance` inside `build_exercise_prompt`)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: `concepts` (already-resolved `config[:concepts]` local in `build_exercise_prompt`), `label`, `third` (now possibly `:security_review`).
- Produces: when `third == :security_review`, the returned prompt string instructs adversarial framing and reuses `concepts` (the language vocabulary) — no separate vocabulary, unlike architecture's `ARCHITECTURE_CONCEPTS`.

- [ ] **Step 1: Write the failing prompt-guidance test**

Add to the `"#build_exercise_prompt"` describe block:

```ruby
    it "instructs adversarial security framing and reuses the language vocabulary (not a separate one) when third: :security_review" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :security_review)
      expect(prompt.downcase).to include("security review")
      expect(prompt.downcase).to include("mitigation")
      expect(prompt).to include(AiService::RAILS_CONCEPTS.join(", "))
      expect(prompt).not_to include(AiService::ARCHITECTURE_CONCEPTS.join(", "))
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "adversarial security framing"`
Expected: FAIL — `third: :security_review` currently falls to the `else` (challenge) branch of `third_guidance`.

- [ ] **Step 3: Convert `third_guidance`'s `if/else` to a `case` and add the security_review branch**

In `app/services/ai_service.rb`, replace the `third_guidance =` assignment (lines 499-518) with:

```ruby
    third_guidance =
      case third
      when :architecture
        <<~ARCH.chomp
          - The third section is an ARCHITECTURE decision, not a coding task. Present 2-3 viable options and ask for a decision plus justification. Its reference must center on tradeoffs (plural).
          - Keep the architecture scenario SHORT: 2-3 sentences, ~50 words maximum, and exactly 2-3 concrete constraints total. Usually the observable symptom plus one hard technical constraint is enough — pick only the constraints the decision actually turns on, and leave the rest out. Do NOT stack scale figures, team size, infrastructure detail, budget, and timeline into one scenario.
          - Short does not mean vague: name real numbers and real systems for the 2-3 constraints you do include. Fewer constraints, not fuzzier ones.
          - The architecture question itself is one sentence — do not restate the scenario in it.
          - Choose the code_review and pattern concepts from this vocabulary, exactly one each: #{concepts.join(", ")}
          - Choose the architecture section's concept from this SEPARATE vocabulary, exactly one: #{ARCHITECTURE_CONCEPTS.join(", ")}
          - The architecture reference's "diagram" must be valid Mermaid source using ONLY `flowchart TD` or `graph LR`. Maximum 8 nodes. No styling directives, no subgraphs, no click handlers, no classDef — narrow syntax parses reliably, clever syntax does not.
          - Node labels must be short (a few words). Use quoted labels like A["Order service"] when a label contains spaces or punctuation.
          - The diagram should show the STRUCTURE the decision is about — the services, data stores, and flows in tension — not a flowchart of how to decide.
          - Return an empty string for "diagram" when a picture would not add anything beyond the text. An empty string is a perfectly good answer and is preferred over a forced or trivial diagram.
        ARCH
      when :security_review
        <<~SEC.chomp
          - The third section is a SECURITY REVIEW, not a general correctness check. The snippet must contain one real, exploitable vulnerability appropriate to #{label}. The question asks the engineer to identify the vulnerability AND propose a mitigation — not just "what's wrong with this code."
          - Choose the security_review concept from this vocabulary, exactly one — the SAME vocabulary as code_review/pattern, no separate security vocabulary: #{concepts.join(", ")}
          - The security_review snippet should be realistic #{label} code, not a contrived toy example — the same bar as code_review's snippet.
        SEC
      else
        <<~CH.chomp
          - The challenge starter_code should give enough scaffold to get started without giving away the answer.
          - Choose each section's concept from this fixed vocabulary, exactly one per section: #{concepts.join(", ")}
        CH
      end
```

- [ ] **Step 4: Run to verify all `#build_exercise_prompt` tests pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "#build_exercise_prompt"`
Expected: PASS

- [ ] **Step 5: Run the full file**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Add security_review generation guidance to build_exercise_prompt"
```

---

### Task 7: `DailyExercise#security_review` accessor and `#third_key` helper

**Files:**
- Modify: `app/models/daily_exercise.rb`
- Test: `spec/models/daily_exercise_spec.rb`

**Interfaces:**
- Produces: `DailyExercise#security_review` (returns `problem_set["security_review"]&.with_indifferent_access`, `nil` when absent — mirrors `#architecture`/`#challenge`); `DailyExercise#third_key` (returns `"architecture"`, `"security_review"`, or `"challenge"` — a plain `String`, not a section hash).
- Consumed by: Task 8 (`build_review_prompt`), Task 9 (controller/user.rb), Task 10 (views).

- [ ] **Step 1: Write the failing model specs**

Add to `spec/models/daily_exercise_spec.rb`, after the existing `describe "#architecture"` block:

```ruby
  describe "#security_review" do
    it "reads the security_review blob with indifferent access, nil when absent" do
      with_sec = DailyExercise.new(problem_set: { "security_review" => { "concept" => "xss_prevention" } })
      without  = DailyExercise.new(problem_set: { "challenge" => { "concept" => "n_plus_one" } })

      expect(with_sec.security_review[:concept]).to eq("xss_prevention")
      expect(without.security_review).to be_nil
    end
  end

  describe "#third_key" do
    it "returns 'architecture' when the architecture key is present" do
      exercise = DailyExercise.new(problem_set: { "architecture" => {} })
      expect(exercise.third_key).to eq("architecture")
    end

    it "returns 'security_review' when present without architecture" do
      exercise = DailyExercise.new(problem_set: { "security_review" => {} })
      expect(exercise.third_key).to eq("security_review")
    end

    it "returns 'challenge' when neither architecture nor security_review is present" do
      exercise = DailyExercise.new(problem_set: { "challenge" => {} })
      expect(exercise.third_key).to eq("challenge")
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/models/daily_exercise_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'security_review'` / `'third_key'`.

- [ ] **Step 3: Implement both methods**

Replace the body of `app/models/daily_exercise.rb` (the four `def code_review = ...` lines and everything after) with:

```ruby
  def code_review       = problem_set["code_review"]&.with_indifferent_access
  def pattern            = problem_set["pattern"]&.with_indifferent_access
  def challenge          = problem_set["challenge"]&.with_indifferent_access
  def architecture       = problem_set["architecture"]&.with_indifferent_access
  def security_review    = problem_set["security_review"]&.with_indifferent_access

  # Which of the three possible third-section shapes this exercise's
  # problem_set actually holds. Replaces the ad hoc `arch ? "architecture" :
  # "challenge"` pattern that build_review_prompt used before a third shape
  # (security_review) existed.
  def third_key
    return "architecture"    if problem_set.key?("architecture")
    return "security_review" if problem_set.key?("security_review")
    "challenge"
  end
end
```

(Only the method definitions change; the class declaration, `belongs_to`/`has_one`, `LANGUAGES`, validations, and `for_date` scope above them are untouched.)

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/models/daily_exercise_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/models/daily_exercise.rb spec/models/daily_exercise_spec.rb
git commit -m "Add DailyExercise#security_review accessor and #third_key discriminator"
```

---

### Task 8: Security Review evaluation criteria (`build_review_prompt`)

**Files:**
- Modify: `app/services/ai_service.rb:554-611` (`build_review_prompt`)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: `exercise.third_key` (from Task 7), `exercise.security_review` (from Task 7).
- Produces: for `exercise.third_key == "security_review"`, the review prompt asks for vulnerability-identification + mitigation-soundness criteria (not a single expected answer) and requests `improved_code` as the mitigated snippet.

- [ ] **Step 1: Write the failing review-prompt tests**

Add a new context to the `"#review_response"` describe block in `spec/services/ai_service_spec.rb`, alongside the existing `context "architecture third section"` block:

```ruby
    context "security_review third section" do
      def security_review_exercise
        DailyExercise.new(
          language: "ruby_rails",
          problem_set: {
            "code_review" => { "question" => "cr?", "snippet" => "code" },
            "pattern"     => { "title" => "P", "question" => "pat?" },
            "security_review" => {
              "title" => "S",
              "question" => "What vulnerability exists here, and how would you mitigate it?",
              "snippet" => "User.new(params[:user])"
            }
          }
        )
      end

      it "evaluates vulnerability identification and mitigation soundness, not a single expected answer" do
        resp = DailyResponse.new(answers: { "security_review" => "Mass assignment; use strong params" })
        prompt = service.send(:build_review_prompt, security_review_exercise, resp)

        expect(prompt).to include("What vulnerability exists here")
        expect(prompt.downcase).to include("mitigation")
        expect(prompt).to include('"security_review"')
        expect(prompt).not_to include("Coding Challenge:")
        expect(prompt).to include('For this section "improved_code" must show the mitigated version of the snippet.')
      end

      it "asks for improved_code covering code_review, pattern, and security_review" do
        resp = DailyResponse.new(answers: {})
        prompt = service.send(:build_review_prompt, security_review_exercise, resp)
        expect(prompt).to include("corrected/improved code for code_review, pattern, and security_review")
      end
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "security_review third section"`
Expected: FAIL — `build_review_prompt` currently only branches on `exercise.architecture` truthiness, so a `security_review`-shaped exercise falls into the challenge branch and looks for `exercise.challenge["question"]` (`nil`), raising `NoMethodError`.

- [ ] **Step 3: Rewrite `build_review_prompt` to dispatch on `exercise.third_key`**

Replace the full method body in `app/services/ai_service.rb` (lines 554-611) with:

```ruby
  def build_review_prompt(exercise, daily_response)
    answers   = daily_response.answers
    third_key = exercise.third_key

    third_block =
      case third_key
      when "architecture"
        arch = exercise.architecture
        <<~ARCH.chomp
          Architecture decision (#{arch["title"]}): #{arch["question"]}
          Scenario/constraints: #{arch["scenario"]}
          Their answer: #{answers["architecture"].presence || "(skipped)"}

          Evaluate the architecture answer on the DEPTH of its reasoning, not a single correct answer:
          - Did they weigh real tradeoffs between the options?
          - Did they address the stated constraints (scale, team, reliability, tech debt)?
          - Did they consider alternatives rather than asserting one option?
          For this section "improved_code" must be an empty string.
        ARCH
      when "security_review"
        sec = exercise.security_review
        <<~SEC.chomp
          Security Review (#{sec["title"]}): #{sec["question"]}
          Snippet: #{sec["snippet"]}
          Their answer: #{answers["security_review"].presence || "(skipped)"}

          Evaluate on whether they correctly identified a real, exploitable vulnerability and whether their proposed mitigation is sound — not against one single expected answer. Give partial credit in "missed" for identifying the vulnerability without a complete mitigation, or vice versa.
          For this section "improved_code" must show the mitigated version of the snippet.
        SEC
      else
        <<~CH.chomp
          Coding Challenge: #{exercise.challenge["question"]}
          Their answer: #{answers["challenge"].presence || "(skipped)"}
        CH
      end

    improved_code_note =
      third_key == "architecture" ?
        "corrected/improved code for code_review and pattern (empty string for architecture)" :
        "corrected/improved code for code_review, pattern, and #{third_key}"

    <<~PROMPT
      Review these Code Gym answers. For each section, return a JSON object with:
      - "rating": "beginner" | "developing" | "solid" | "strong"
      - "correct": array of strings — each entry one distinct thing they got right
      - "missed": array of strings — each entry one distinct thing they missed or got wrong
      - "better_questions": array of strings — each entry one question they should have asked themselves
      - "next_step": string — one specific thing to study
      - "improved_code": string — #{improved_code_note}

      Each array entry must be ONE self-contained idea in one or two sentences.
      Never pack several points into one entry, and never number points inside an
      entry ("1) ... 2) ...") — separate ideas belong in separate entries. Use an
      empty array when there is nothing to say for that field.

      For "pattern", improved_code must show the refactored structure that addresses
      what they missed — the classes, methods, and boundaries the pattern calls for —
      not a one-line tweak. A pattern fix is structural; show enough of the shape to
      make the structure obvious.

      Exercise:
      Code Review question: #{exercise.code_review["question"]}
      Code snippet: #{exercise.code_review["snippet"]}
      Their answer: #{answers["code_review"].presence || "(skipped)"}

      Pattern question (#{exercise.pattern["title"]}): #{exercise.pattern["question"]}
      Their answer: #{answers["pattern"].presence || "(skipped)"}

      #{third_block}

      Return JSON with keys: "code_review", "pattern", "#{third_key}" — each matching the schema above.
    PROMPT
  end
```

- [ ] **Step 4: Run to verify all `#review_response`/`build_review_prompt` tests pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "#review_response"`
Expected: PASS — including the pre-existing architecture and challenge contexts, which must still pass unchanged (they exercise `exercise.third_key` returning `"architecture"`/`"challenge"` correctly via Task 7's implementation).

- [ ] **Step 5: Run the full file**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Dispatch build_review_prompt on DailyExercise#third_key, add security_review criteria"
```

---

### Task 9: Controller and User model — permit, tag, and surface security_review

**Files:**
- Modify: `app/controllers/responses_controller.rb` (lines 273-302)
- Modify: `app/models/user.rb:94` (`recent_performance`)
- Test: `spec/requests/responses_spec.rb`
- Test: `spec/models/user_spec.rb`

**Interfaces:**
- Consumes: `exercise.problem_set` keys (already generic — no interface change needed there).
- Produces: `security_review` now flows through `response_params`, `exercise_concept_tags`, `enqueue_concept_references`, and `recent_performance`'s scenario list exactly like `architecture`/`challenge` do today.

- [ ] **Step 1: Write the failing request specs**

Add to `spec/requests/responses_spec.rb`, in the `"POST /responses concept_tags copy"` describe block, after the existing architecture tests:

```ruby
    it "tags and saves a security_review third section's concept and answer" do
      create_exercise(
        "code_review"      => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"          => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "security_review"  => { "title" => "t", "question" => "q", "concept" => "sql_injection_prevention" }
      )

      post responses_path,
        params: { response: { answers: { security_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      resp = DailyResponse.last
      expect(resp.answers["security_review"]).to eq("a" * 20)
      expect(resp.concept_tags).to eq(
        "code_review" => "n_plus_one", "pattern" => "memoization", "security_review" => "sql_injection_prevention"
      )
    end
```

Add to the `"POST /responses concept reference generation"` describe block (which already `include`s `ActiveJob::TestHelper` — reuse that, don't add a second include), right after the existing "enqueues the architecture concept under the 'architecture' language bucket" test:

```ruby
    it "enqueues the security_review concept under the exercise's own language bucket, not a separate one" do
      create_exercise(
        "code_review"     => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"         => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "security_review" => { "title" => "t", "question" => "q", "concept" => "sql_injection_prevention" }
      )

      expect {
        post responses_path,
          params: { response: { answers: { security_review: "a" * 20 }, submit: "1" } }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.to have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "sql_injection_prevention", language: "ruby_rails", user_id: user.id)
        .exactly(:once)
        .and have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
        .exactly(:once)
        .and have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "memoization", language: "ruby_rails", user_id: user.id)
        .exactly(:once)
    end
```

This matches the exact `have_enqueued_job`/`ActiveJob::TestHelper` convention the file already uses for the architecture case, rather than a bare `expect(...).to receive(...)` mock.

Add to `spec/models/user_spec.rb`, near existing `recent_performance` scenario tests (find the test asserting `scenarios:` includes `"architecture"` framings, and add an analogous one):

```ruby
    it "includes a security_review section's scenario in recent_performance's framings" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current - 1, generated_at: Time.current,
        problem_set: { "security_review" => { "scenario" => "a legacy GraphQL layer needs a fix" } }
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current - 1,
                            answers: { "security_review" => "x" * 20 })

      performance = user.recent_performance
      expect(performance.first[:scenarios]).to include("a legacy GraphQL layer needs a fix")
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/requests/responses_spec.rb spec/models/user_spec.rb`
Expected: FAIL — `security_review` answers/ratings are stripped by the strong-params allowlist, `exercise_concept_tags` doesn't include it, and `recent_performance`'s scenario list doesn't check it.

- [ ] **Step 3: Update `response_params` and `exercise_concept_tags`**

In `app/controllers/responses_controller.rb`, replace:

```ruby
  def response_params
    @response_params ||= params.require(:response).permit(
      :submit, :feedback_text,
      answers: [ :code_review, :pattern, :challenge, :architecture ],
      section_ratings: [ :code_review, :pattern, :challenge, :architecture ]
    )
  end

  def exercise_concept_tags(exercise)
    %w[code_review pattern challenge architecture]
      .index_with { |section| exercise.problem_set.dig(section, "concept") }
      .compact
  end
```

with:

```ruby
  def response_params
    @response_params ||= params.require(:response).permit(
      :submit, :feedback_text,
      answers: [ :code_review, :pattern, :challenge, :architecture, :security_review ],
      section_ratings: [ :code_review, :pattern, :challenge, :architecture, :security_review ]
    )
  end

  def exercise_concept_tags(exercise)
    %w[code_review pattern challenge architecture security_review]
      .index_with { |section| exercise.problem_set.dig(section, "concept") }
      .compact
  end
```

(The comment above `response_params` mentioning "the two possible third keys" at line 21-22 should also be updated to say "the three possible third keys" — do this as part of this same edit.)

- [ ] **Step 4: Update `User#recent_performance`'s scenario section list**

In `app/models/user.rb`, replace line 94:

```ruby
      scenarios = %w[code_review pattern challenge architecture].filter_map do |section|
```

with:

```ruby
      scenarios = %w[code_review pattern challenge architecture security_review].filter_map do |section|
```

- [ ] **Step 5: Run to verify all new and existing tests pass**

Run: `bundle exec rspec spec/requests/responses_spec.rb spec/models/user_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/controllers/responses_controller.rb app/models/user.rb spec/requests/responses_spec.rb spec/models/user_spec.rb
git commit -m "Permit, tag, and surface security_review through the response pipeline"
```

---

### Task 10: Regression coverage — bucket resolution and improved_code visibility

**Files:**
- Test only: `spec/models/concept_mastery_spec.rb`
- Test only: `spec/models/daily_response_spec.rb`

No production code changes in this task — it verifies (and locks in with a regression test) the spec's central claim that security_review concepts need no special-casing in `ConceptMastery.record_review!` or `DailyResponse#improved_code_visible?`, because they're ordinary language-bucketed concepts, not a pseudo-language like `"architecture"`.

**Interfaces:**
- Consumes: `ConceptMastery.record_review!` (unchanged, from Task 9's context), `DailyResponse#improved_code_visible?` (unchanged).

- [ ] **Step 1: Write the failing (as in: not-yet-existing) bucket-resolution regression test**

Add to `spec/models/concept_mastery_spec.rb`, reusing the file's existing `review!` helper (which already accepts a `section:` keyword):

```ruby
  it "buckets a security_review-tagged concept under the exercise's language, not a separate 'architecture'-style bucket" do
    cm = review!(concept: "sql_injection_prevention", self_rating: "too_hard", ai_rating: "developing", section: "security_review")
    expect(cm.language).to eq("ruby_rails")
  end
```

- [ ] **Step 2: Run to verify it currently passes (this is a regression/confirmation test, not a new-behavior test)**

Run: `bundle exec rspec spec/models/concept_mastery_spec.rb -e "buckets a security_review-tagged concept"`
Expected: PASS immediately — `ConceptMastery.record_review!`'s bucket ternary (`sections.include?("architecture") ? "architecture" : response.daily_exercise.language`) already falls through correctly for any section name other than `"architecture"`. This step exists to lock in that guarantee with an explicit test, not to drive new code.

- [ ] **Step 3: Write the failing (as in: not-yet-existing) improved_code-visibility regression test**

Add to `spec/models/daily_response_spec.rb`, near the existing `#improved_code_visible?` tests:

```ruby
  describe "#improved_code_visible? for security_review" do
    it "is not excluded like architecture — it follows the normal concept-exposure gate" do
      exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
        problem_set: { "security_review" => { "concept" => "xss_prevention" } })
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
        answers: { "security_review" => "x" * 20 },
        concept_tags: { "security_review" => "xss_prevention" })

      # No prior exposure yet — gated closed, same rule code_review/pattern follow.
      expect(response.improved_code_visible?("security_review")).to be false
    end
  end
```

(Use whatever `let(:user)` / setup convention `daily_response_spec.rb` already uses at the top of the file — inspect the file's existing `describe "#improved_code_visible?"` block first and match its exact fixture style rather than inventing a new one.)

- [ ] **Step 4: Run to verify it currently passes**

Run: `bundle exec rspec spec/models/daily_response_spec.rb -e "not excluded like architecture"`
Expected: PASS immediately — `improved_code_visible?`'s only special-case is `return false if section.to_s == "architecture"`; `"security_review"` never hits that branch.

- [ ] **Step 5: Run both full files**

Run: `bundle exec rspec spec/models/concept_mastery_spec.rb spec/models/daily_response_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add spec/models/concept_mastery_spec.rb spec/models/daily_response_spec.rb
git commit -m "Add regression tests confirming security_review needs no mastery/visibility special-casing"
```

---

### Task 11: Security Review view partial + wiring into the dashboard and history

**Files:**
- Create: `app/views/responses/_security_review_section.html.erb`
- Modify: `app/views/dashboard/_exercise.html.erb:79-102`
- Modify: `app/views/responses/_answered_sections.html.erb:36-52`

**Interfaces:**
- Consumes: `exercise.security_review` / `exercise.third_key` (Task 7), `response.answers["security_review"]`, `response.self_rating_for("security_review")`, `DailyResponse::SELF_RATING_LABELS`, `glossary_wrap`, `concept_reference_for`, `first_exposure?`, `hljs_language` — all pre-existing helpers used identically by the code_review/challenge sections.
- Produces: a rendered "3 — Security Review" section, code-shaped (snippet + textarea + rating row), no Mermaid diagram, no options list.

- [ ] **Step 1: Create the partial**

Write `app/views/responses/_security_review_section.html.erb`:

```erb
<%# Security Review third section, shared by the dashboard form (submitted: false)
    and the read-only render of a submitted day (submitted: true), which appears
    on the dashboard after submitting and on every history entry.
    Locals: sec, response, submitted. %>
<div class="section">
  <div class="section-label">3 — Security Review: <%= glossary_wrap(sec["title"], sec["glossary"]) %></div>
  <div class="question"><%= glossary_wrap(sec["question"], sec["glossary"]) %></div>
  <pre class="snippet"><code<% if (lang = hljs_language(response.daily_exercise.language)) %> data-hljs="<%= lang %>"<% end %>><%= sec["snippet"] %></code></pre>
  <% if (ref = concept_reference_for(sec["concept"], response.daily_exercise.language)) %>
    <%= render "shared/concept_reference", reference: ref,
          open: !submitted && first_exposure?(sec["concept"], response.daily_exercise.language, response.date) %>
  <% end %>
  <%= render "dashboard/teaching_hint", note: sec["teaching_note"], field: "security_review", submitted: submitted, answer: response.answers["security_review"] %>
  <% if submitted %>
    <div class="answer-display"><%= response.answers["security_review"].presence || "(skipped)" %></div>
  <% else %>
    <textarea name="response[answers][security_review]" class="answer" placeholder="What's exploitable here, and how would you mitigate it?" data-field="security_review"><%= response.answers["security_review"] %></textarea>
    <div class="rating-row" data-rating-for="security_review">
      <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
        <button type="button" class="rating-btn<%= " active" if response.self_rating_for("security_review") == value %>" data-rating-for="security_review" data-rating="<%= value %>"><%= label.upcase_first %></button>
      <% end %>
    </div>
  <% end %>
</div>
```

- [ ] **Step 2: Wire it into the dashboard's unsubmitted form**

In `app/views/dashboard/_exercise.html.erb`, replace the third-section block (lines 79-102):

```erb
    <% if (arch = exercise.architecture) %>
      <%= render "responses/architecture_section", arch: arch, response: response, submitted: false %>
    <% else %>
      <% ch = exercise.challenge %>
      ...
    <% end %>
```

with:

```erb
    <% if (arch = exercise.architecture) %>
      <%= render "responses/architecture_section", arch: arch, response: response, submitted: false %>
    <% elsif (sec = exercise.security_review) %>
      <%= render "responses/security_review_section", sec: sec, response: response, submitted: false %>
    <% else %>
      <% ch = exercise.challenge %>
      <div class="section">
        <div class="section-label">3 — Coding Challenge</div>
        <% if ch["scenario"].present? %><div class="section-scenario"><%= glossary_wrap(ch["scenario"], ch["glossary"]) %></div><% end %>
        <div class="question"><%= glossary_wrap(ch["question"], ch["glossary"]) %></div>
        <% if ch["starter_code"].present? %>
          <pre class="snippet"><code<% if (lang = hljs_language(exercise.language)) %> data-hljs="<%= lang %>"<% end %>><%= ch["starter_code"] %></code></pre>
        <% end %>
        <% if (ref = concept_reference_for(ch["concept"], exercise.language)) %>
          <%= render "shared/concept_reference", reference: ref,
                open: first_exposure?(ch["concept"], exercise.language, exercise.date) %>
        <% end %>
        <%= render "dashboard/teaching_hint", note: ch["teaching_note"], field: "challenge", submitted: false, answer: response.answers["challenge"] %>
        <textarea name="response[answers][challenge]" class="answer code-answer" placeholder="# Your implementation…" data-field="challenge"><%= response.answers["challenge"] %></textarea>
        <div class="rating-row" data-rating-for="challenge">
          <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
            <button type="button" class="rating-btn<%= " active" if response.self_rating_for("challenge") == value %>" data-rating-for="challenge" data-rating="<%= value %>"><%= label.upcase_first %></button>
          <% end %>
        </div>
      </div>
    <% end %>
```

(Only the `<% if (arch = exercise.architecture) %>` line changes shape, by inserting the `elsif`; the `challenge` branch's body is unchanged, reproduced above in full only so this diff is unambiguous.)

- [ ] **Step 3: Wire it into the read-only render (`_answered_sections.html.erb`)**

In `app/views/responses/_answered_sections.html.erb`, replace lines 36-52:

```erb
<% if (arch = exercise.architecture) %>
  <%= render "responses/architecture_section", arch: arch, response: response, submitted: true %>
<% elsif (ch = exercise.challenge) %>
  ...
<% end %>
```

with:

```erb
<% if (arch = exercise.architecture) %>
  <%= render "responses/architecture_section", arch: arch, response: response, submitted: true %>
<% elsif (sec = exercise.security_review) %>
  <%= render "responses/security_review_section", sec: sec, response: response, submitted: true %>
<% elsif (ch = exercise.challenge) %>
  <div class="section">
    <div class="section-label">3 — Coding Challenge</div>
    <% if ch["scenario"].present? %><div class="section-scenario"><%= glossary_wrap(ch["scenario"], ch["glossary"]) %></div><% end %>
    <div class="question"><%= glossary_wrap(ch["question"], ch["glossary"]) %></div>
    <% if ch["starter_code"].present? %>
      <pre class="snippet"><code<% if (lang = hljs_language(exercise.language)) %> data-hljs="<%= lang %>"<% end %>><%= ch["starter_code"] %></code></pre>
    <% end %>
    <% if (ref = concept_reference_for(ch["concept"], exercise.language)) %>
      <%= render "shared/concept_reference", reference: ref %>
    <% end %>
    <%= render "dashboard/teaching_hint", note: ch["teaching_note"], field: "challenge", submitted: true, answer: response.answers["challenge"] %>
    <div class="answer-display"><%= response.answers["challenge"].presence || "(skipped)" %></div>
  </div>
<% end %>
```

- [ ] **Step 4: Manually verify in the browser**

Since this touches the dashboard's live JS-driven form (autosave, progress bar, submit gating — none of which needs code changes, per the design's note that `sectionFields` is derived generically from the DOM, but it's worth confirming nothing broke):

1. Start the app: `bin/dev`
2. In `rails console`, create a user with an API key stubbed/set, and a `DailyExercise` whose `problem_set` has a `"security_review"` key (reuse the shape from Task 8's test fixture).
3. Load the dashboard in a browser. Confirm: the "3 — Security Review" section renders with a snippet, a textarea, and a rating row; typing in it updates the progress bar; rating it enables Submit once all three sections are rated; submitting shows the read-only render with the same section.
4. Confirm the existing architecture and challenge paths still render correctly for exercises generated with those third kinds (no regression).

- [ ] **Step 5: Commit**

```bash
git add app/views/responses/_security_review_section.html.erb app/views/dashboard/_exercise.html.erb app/views/responses/_answered_sections.html.erb
git commit -m "Add security_review view partial, wire into dashboard and history rendering"
```

---

### Task 12: End-to-end request spec for a security_review-shaped day

**Files:**
- Test only: `spec/requests/responses_spec.rb` (or a new `spec/requests/security_review_spec.rb` if the existing file's `describe` structure doesn't have a natural home — check first and prefer extending the existing file to avoid a near-duplicate `let(:user)`/helper setup)

**Interfaces:**
- Consumes: everything built in Tasks 1-11. This task has no new production interfaces — it's the closing verification that the full path (generate → dashboard render → submit → review → history render) works for a `security_review`-shaped exercise, the same way existing specs already cover `architecture` and `challenge`.

- [ ] **Step 1: Write the end-to-end request spec**

Add to `spec/requests/responses_spec.rb`:

```ruby
  describe "security_review end-to-end" do
    def create_security_review_exercise
      DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review"      => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
          "pattern"          => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
          "security_review"  => { "title" => "Injection risk", "question" => "What's exploitable here?",
                                  "snippet" => "User.where(\"name = '\#{params[:name]}'\")",
                                  "concept" => "sql_injection_prevention" }
        }
      )
    end

    it "accepts a submitted answer, rating, and completes review through history" do
      exercise = create_security_review_exercise

      post responses_path,
        params: { response: {
          answers: { code_review: "a" * 20, pattern: "b" * 20, security_review: "c" * 20 },
          section_ratings: { code_review: "right_level", pattern: "right_level", security_review: "right_level" },
          submit: "1"
        } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      resp = DailyResponse.last
      expect(resp.submitted?).to be true
      expect(resp.answers["security_review"]).to eq("c" * 20)
      expect(resp.concept_tags["security_review"]).to eq("sql_injection_prevention")

      fake_review = {
        "code_review"     => { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "" },
        "pattern"         => { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "" },
        "security_review" => { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "fixed = User.where(name: params[:name])" }
      }
      # Matches this file's existing convention for stubbing the review call
      # (see the "POST /responses/:id/review" describe block) rather than
      # allow_any_instance_of, which this codebase's specs don't otherwise use.
      fake_service = instance_double(ClaudeService, review_response: fake_review)
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(resp)
      expect(response).to redirect_to(history_path(anchor: "response-#{resp.id}"))
      expect(resp.reload.ai_review["security_review"]["rating"]).to eq("solid")

      get history_path
      expect(response.body).to include("Injection risk").or include("Security review")
    end
  end
```

Adjust the final `get history_path` assertion once you've run it once and can see the actual rendered text (the partial from Task 11 renders `sec["title"]` inside the section label — assert on whatever literal text the render produces; don't guess blindly if the first assertion fails, inspect `response.body`).

- [ ] **Step 2: Run it**

Run: `bundle exec rspec spec/requests/responses_spec.rb -e "security_review end-to-end"`
Expected: PASS. If it fails, the failure output will point at exactly which layer (controller allowlist, view partial, or `AiService` prompt/schema) regressed — fix forward rather than loosening the assertions.

- [ ] **Step 3: Run the entire suite**

Run: `bundle exec rspec`
Expected: PASS — full suite green, confirming no cross-file regressions from any of the 11 preceding tasks.

- [ ] **Step 4: Commit**

```bash
git add spec/requests/responses_spec.rb
git commit -m "Add end-to-end request spec covering a security_review-shaped exercise day"
```

---

## Post-plan checklist

- [ ] All 4 changes from the spec are implemented: security concepts (Tasks 1, 10), TypeScript-flavored concepts (Task 2), scenario-domain grounding (Task 3), Security Review (Tasks 4-9, 11, 12).
- [ ] `bundle exec rspec` is green.
- [ ] No migration was added or needed (confirm: `git log --oneline -- db/migrate` shows nothing new since this plan started).
- [ ] Manually verified in-browser per Task 11 Step 4.
- [ ] Branch hygiene: this work landed on its own branch, separate from any unrelated in-flight work (see the note about `glossary-tooltips` from the brainstorming session) — confirm before opening a PR.
