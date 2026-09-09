# Test-Analysis Content Folded Into code_review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let code_review's snippet occasionally be a test file (RSpec/Jest-style) exhibiting a real test smell, by adding two testing-specific concepts to the existing concept vocabularies and extending code_review's one prompt instruction — no new section kind, schema, or grading logic.

**Architecture:** Two concept-vocabulary additions in `app/services/ai_service.rb` plus a one-line extension to the existing code_review prompt instruction. `code_review` is a fixed top-level schema key used every day regardless of the day's "third" section, and `ExerciseSection::CodeReview` is an empty subclass — neither needs a code change beyond the vocabulary/prompt edits.

**Tech Stack:** Ruby, RSpec.

## Global Constraints

- No new `ExerciseSection` subclass, no new rotation weight, no new grading logic, no new review-prompt branch.
- No changes to `pattern`, `challenge`, `architecture`, `security_review`, or `parsons_problem` schema blocks or their prompt instructions.
- No changes to `DailyPlan`'s rotation logic or the mastery-tier system.
- No migration — prompt/vocabulary only.
- New concepts: `over_mocking` and `testing_implementation_not_behavior`, added to both `RAILS_CONCEPTS` and `JS_CONCEPTS`.
- Frequency wording: roughly 1 in 4 sessions.

---

### Task 1: Add test-analysis concepts and extend code_review's prompt instruction

**Files:**
- Modify: `app/services/ai_service.rb:33-38` (`RAILS_CONCEPTS`)
- Modify: `app/services/ai_service.rb:40-46` (`JS_CONCEPTS`)
- Modify: `app/services/ai_service.rb:633` (code_review prompt instruction)
- Test: `spec/services/ai_service_spec.rb` (the `describe "RAILS_CONCEPTS"` block starting at line 188, the `describe "JS_CONCEPTS"` block starting at line 204, and the `describe "#build_exercise_prompt"` block starting around line 273 — exact line numbers will have shifted from edits earlier in the file; locate by content, not line number)

**Interfaces:**
- Consumes: `AiService::RAILS_CONCEPTS` and `AiService::JS_CONCEPTS` (frozen `Array` constants, already defined) — this task only adds two entries to each.
- Consumes: `AiService#build_exercise_prompt(user, language = "ruby_rails", third: :challenge, ...)` (instance method, already defined) — this task only changes the content of the string it returns.
- Produces: nothing new is exposed; existing constants grow by two entries each, and the prompt string gains one clause.

- [ ] **Step 1: Write the failing vocabulary tests**

In `spec/services/ai_service_spec.rb`, inside the existing `describe "RAILS_CONCEPTS"` block, update the size assertion and add a new `it` block:

```ruby
    it "is a frozen 20-entry vocabulary" do
      expect(AiService::RAILS_CONCEPTS.size).to eq(20)
      expect(AiService::RAILS_CONCEPTS).to be_frozen
      expect(AiService::RAILS_CONCEPTS).to include("n_plus_one", "transaction_safety", "error_handling")
    end
```

(replace the existing `"is a frozen 18-entry vocabulary"` test with this — same body, updated count from 18 to 20)

Then add a new test in the same `describe "RAILS_CONCEPTS"` block, after the existing `"includes the two Rails security concepts..."` test:

```ruby
    it "includes the two test-analysis concepts added for code_review's occasional test-file variant" do
      expect(AiService::RAILS_CONCEPTS).to include("over_mocking", "testing_implementation_not_behavior")
    end
```

Inside the existing `describe "JS_CONCEPTS"` block, update the size assertion the same way:

```ruby
    it "is a frozen 22-entry vocabulary" do
      expect(AiService::JS_CONCEPTS.size).to eq(22)
      expect(AiService::JS_CONCEPTS).to be_frozen
      expect(AiService::JS_CONCEPTS).to include("closures", "prototype_chain", "hooks_dependencies")
    end
```

(replace the existing `"is a frozen 20-entry vocabulary"` test with this — same body, updated count from 20 to 22)

Then add a new test in the same `describe "JS_CONCEPTS"` block, after the existing `"includes the two JS security concepts..."` test:

```ruby
    it "includes the two test-analysis concepts added for code_review's occasional test-file variant" do
      expect(AiService::JS_CONCEPTS).to include("over_mocking", "testing_implementation_not_behavior")
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "RAILS_CONCEPTS" -e "JS_CONCEPTS"`
Expected: FAIL — the size assertions fail (18/20 actual vs 20/22 expected) and the two new `include` assertions fail (the concepts don't exist yet).

- [ ] **Step 3: Add the two concepts to RAILS_CONCEPTS and JS_CONCEPTS**

In `app/services/ai_service.rb`, change:

```ruby
  RAILS_CONCEPTS = %w[
    n_plus_one transaction_safety memoization service_objects scope_chaining
    idempotency authorization background_jobs caching validations
    callbacks_vs_service query_objects policy_objects indexing concurrency
    error_handling mass_assignment_protection sql_injection_prevention
  ].freeze
```

to:

```ruby
  RAILS_CONCEPTS = %w[
    n_plus_one transaction_safety memoization service_objects scope_chaining
    idempotency authorization background_jobs caching validations
    callbacks_vs_service query_objects policy_objects indexing concurrency
    error_handling mass_assignment_protection sql_injection_prevention
    over_mocking testing_implementation_not_behavior
  ].freeze
```

And change:

```ruby
  JS_CONCEPTS = %w[
    callback_hell promise_chaining closures prototype_chain event_loop_blocking
    this_binding array_mutation_pitfalls debouncing_throttling closures_in_loops
    memory_leaks_listeners hooks_dependencies component_re_renders state_lifting
    controlled_vs_uncontrolled xss_prevention insecure_client_storage
    generics type_guards_narrowing union_intersection_types mapped_conditional_types
  ].freeze
```

to:

```ruby
  JS_CONCEPTS = %w[
    callback_hell promise_chaining closures prototype_chain event_loop_blocking
    this_binding array_mutation_pitfalls debouncing_throttling closures_in_loops
    memory_leaks_listeners hooks_dependencies component_re_renders state_lifting
    controlled_vs_uncontrolled xss_prevention insecure_client_storage
    generics type_guards_narrowing union_intersection_types mapped_conditional_types
    over_mocking testing_implementation_not_behavior
  ].freeze
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "RAILS_CONCEPTS" -e "JS_CONCEPTS"`
Expected: PASS

- [ ] **Step 5: Write the failing prompt-instruction test**

In `spec/services/ai_service_spec.rb`, inside the existing `describe "#build_exercise_prompt"` block, add a new test (place it near the other code_review-related or instruction-style assertions):

```ruby
    it "instructs that the code_review snippet may occasionally be a test file with a test smell" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include(
        "Roughly 1 in 4 sessions, make it an RSpec-style (Rails) or Jest/Vitest-style (JS) test file exhibiting a real test smell instead"
      )
    end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "instructs that the code_review snippet may occasionally be a test file"`
Expected: FAIL — the current instruction text doesn't contain this clause.

- [ ] **Step 7: Extend the code_review prompt instruction**

In `app/services/ai_service.rb`, change:

```ruby
      - The code_review snippet must be realistic #{label} code — not toy examples.
```

to:

```ruby
      - The code_review snippet must be realistic #{label} code — not toy examples. Roughly 1 in 4 sessions, make it an RSpec-style (Rails) or Jest/Vitest-style (JS) test file exhibiting a real test smell instead — same question shape ("what's the issue here, and how would you fix it").
```

- [ ] **Step 8: Run test to verify it passes**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "instructs that the code_review snippet may occasionally be a test file"`
Expected: PASS

- [ ] **Step 9: Run the full ai_service spec file to check for regressions**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: all examples PASS.

- [ ] **Step 10: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Fold test-analysis content into code_review's occasional snippet variety"
```
