# Pattern Question Self-Contained Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the model from writing Pattern-section questions that reference code that isn't shown, by adding an explicit constraint to the `"question"` field description in the pattern JSON schema.

**Architecture:** One-line change to the inline schema string built by `AiService#exercise_schema_for` (`app/services/ai_service.rb:497-505`), covered by one new spec assertion in `spec/services/ai_service_spec.rb`.

**Tech Stack:** Ruby, RSpec.

## Global Constraints

- No schema/field changes — this is a prompt-instruction-only fix (no new/removed/renamed JSON keys).
- No changes to `code_review`, `challenge`, `architecture`, `security_review`, or `parsons_problem` schema blocks.
- Test goes in `spec/services/ai_service_spec.rb`, following the existing convention for prompt-instruction assertions (see the `"never the full answer"` teaching_note check under `describe "#build_exercise_prompt"`).

---

### Task 1: Add self-contained instruction to pattern's question field, with a spec

**Files:**
- Modify: `app/services/ai_service.rb:500`
- Test: `spec/services/ai_service_spec.rb` (new `it` block inside the existing `describe "#build_exercise_prompt"` block, which starts around line 273)

**Interfaces:**
- Consumes: `AiService#build_exercise_prompt(user, language = "ruby_rails", third: :challenge, ...)` (instance method, already defined) — calls into `#exercise_schema_for`, which is where the schema string lives.
- Produces: nothing new is exposed; this only changes the content of the string `build_exercise_prompt` returns.

- [x] **Step 1: Write the failing test**

Add this `it` block inside the existing `describe "#build_exercise_prompt"` block in `spec/services/ai_service_spec.rb` (place it near the other schema/instruction assertions, e.g. right after the `"instructs that teaching notes hint without giving the answer"` test):

```ruby
    it "instructs that pattern's question must be self-contained, with no code reference" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include(
        "\"question\": \"string — conceptual question to answer. Must be fully self-contained: never reference a code snippet, example, or \\\"the code below\\\" — none is shown for this section.\""
      )
    end
```

- [x] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "instructs that pattern's question must be self-contained"`
Expected: FAIL — the current schema string doesn't contain this text (it currently reads `"question": "string — conceptual question to answer",` with no trailing constraint).

- [x] **Step 3: Update the pattern schema field description**

In `app/services/ai_service.rb`, in the `"pattern"` block inside `exercise_schema_for` (around line 500), change:

```ruby
          "question": "string — conceptual question to answer",
```

to:

```ruby
          "question": "string — conceptual question to answer. Must be fully self-contained: never reference a code snippet, example, or \\\"the code below\\\" — none is shown for this section.",
```

The full pattern block (lines 497-505) should read:

```ruby
        "pattern": {
          "title":    "string — pattern name",
          "why":      "string — one sentence on why the pattern exists",
          "question": "string — conceptual question to answer. Must be fully self-contained: never reference a code snippet, example, or \\\"the code below\\\" — none is shown for this section.",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          #{glossary_field}
        },
```

- [x] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "instructs that pattern's question must be self-contained"`
Expected: PASS

- [x] **Step 5: Run the full ai_service spec file to check for regressions**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: all examples PASS (no other spec asserts the old exact text of this field, but this confirms nothing else broke).

- [x] **Step 6: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Forbid code-referencing phrasing in pattern's question field"
```
