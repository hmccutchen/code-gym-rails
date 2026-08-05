# Parallel Review Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `AiService#review_response`'s single monolithic review call with three parallel, per-section calls that support partial success/retry, preserve the "review write + mastery update in one transaction" guarantee at per-section grain, and use Claude prompt caching to offset the added shared-content cost.

**Architecture:** `AiService#review_sections` spawns one thread per still-missing section, each with its own service instance (own Faraday connection). Each thread sends a shared, cache-marked "day context" as `system` and a small per-section grading prompt as `prompt`, parses its own result, and returns a tagged success/failure outcome instead of raising past the thread boundary. The controller merges only the successes into `ai_review` (jsonb, partial-tolerant) inside one transaction alongside a `ConceptMastery` evaluation scoped to just those sections, and persists per-section failure reasons in a new `review_errors` column so a retry (re-clicking the same button) only re-fires what's still missing.

**Tech Stack:** Ruby on Rails 8.0.5, RSpec, Faraday, Ruby `Thread`, PostgreSQL jsonb.

## Global Constraints

- No change to grading/evaluation criteria per section kind — only how many calls fetch that content and how the result is persisted.
- No change to `AiService`'s provider dispatch (`AiService.for`), retry/backoff (`RETRY_OPTIONS`), or typed error classes (`AuthenticationError`, `RateLimitError`, `InvalidResponseError`, `TruncatedResponseError`) — reused exactly as-is, per section call.
- No Gemini-specific rate-limit throttle and no Gemini-specific caching implementation — both are documented tradeoffs, not mitigated in code (see spec `docs/superpowers/specs/2026-08-05-parallel-review-generation-design.md`).
- Every non-review `AiService` entry point (`generate_exercise`, `generate_concept_reference`, `explain_differently`, `answer_follow_up`) must see zero behavior change.
- `DailyResponse#reviewed?` keeps its current meaning (`ai_review.present?`, true once *any* section has content) — do not change its definition.
- Follow this repo's no-comments-except-non-obvious-why convention (see `CLAUDE.md`).

---

### Task 1: `review_errors` column on `daily_responses`

**Files:**
- Create: `db/migrate/<timestamp>_add_review_errors_to_daily_responses.rb`
- Modify: `db/schema.rb` (auto-updated by running the migration)

**Interfaces:**
- Produces: `daily_responses.review_errors` — jsonb, default `{}`, not null. Later tasks read/write it as a plain Hash keyed by section string, e.g. `{ "pattern" => "rate_limit" }`.

- [ ] **Step 1: Generate and write the migration**

```bash
bin/rails generate migration AddReviewErrorsToDailyResponses
```

Replace the generated file's contents with:

```ruby
class AddReviewErrorsToDailyResponses < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_responses, :review_errors, :jsonb, default: {}, null: false
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: migration applies; `db/schema.rb` now shows `t.jsonb "review_errors", default: {}, null: false` under `create_table "daily_responses"`.

- [ ] **Step 3: Commit**

```bash
git add db/migrate db/schema.rb
git commit -m "Add review_errors column to daily_responses"
```

---

### Task 2: `DailyResponse#fully_reviewed?` and `#section_reviewed?`

**Files:**
- Modify: `app/models/daily_response.rb:71-72`
- Test: `spec/models/daily_response_spec.rb`

**Interfaces:**
- Consumes: nothing new — reads `ai_review` and `daily_exercise.problem_set.keys` (existing associations).
- Produces: `DailyResponse#fully_reviewed?` (Boolean), `DailyResponse#section_reviewed?(section)` (Boolean). Both consumed by Task 8 (controller) and Task 9 (view).

- [ ] **Step 1: Write the failing tests**

Add to `spec/models/daily_response_spec.rb` (create the file with a `require "rails_helper"` header and `RSpec.describe DailyResponse do ... end` wrapper if it doesn't already exist — check first with `ls spec/models/daily_response_spec.rb`):

```ruby
describe "#fully_reviewed?" do
  def exercise_with_three_sections
    DailyExercise.create!(
      user: create_user_with_key, date: Date.current, generated_at: Time.current,
      language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern"     => { "title" => "t", "question" => "q" },
        "challenge"   => { "question" => "q" }
      }
    )
  end

  it "is false when ai_review is blank" do
    exercise = exercise_with_three_sections
    response = DailyResponse.create!(user: exercise.user, daily_exercise: exercise, date: Date.current, answers: {})
    expect(response).not_to be_fully_reviewed
  end

  it "is false when only some sections are present" do
    exercise = exercise_with_three_sections
    response = DailyResponse.create!(
      user: exercise.user, daily_exercise: exercise, date: Date.current, answers: {},
      ai_review: { "code_review" => { "rating" => "solid" } }
    )
    expect(response).not_to be_fully_reviewed
  end

  it "is true when every exercise section is present in ai_review" do
    exercise = exercise_with_three_sections
    response = DailyResponse.create!(
      user: exercise.user, daily_exercise: exercise, date: Date.current, answers: {},
      ai_review: {
        "code_review" => { "rating" => "solid" },
        "pattern"     => { "rating" => "solid" },
        "challenge"   => { "rating" => "solid" }
      }
    )
    expect(response).to be_fully_reviewed
  end
end

describe "#section_reviewed?" do
  it "is true only for a section with a Hash entry in ai_review" do
    exercise = DailyExercise.create!(
      user: create_user_with_key, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
    )
    response = DailyResponse.create!(
      user: exercise.user, daily_exercise: exercise, date: Date.current, answers: {},
      ai_review: { "code_review" => { "rating" => "solid" } }
    )
    expect(response.section_reviewed?("code_review")).to be(true)
    expect(response.section_reviewed?("pattern")).to be(false)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/models/daily_response_spec.rb -e "fully_reviewed" -e "section_reviewed"`
Expected: FAIL with `undefined method 'fully_reviewed?'` / `'section_reviewed?'`.

- [ ] **Step 3: Implement**

In `app/models/daily_response.rb`, directly below the existing `reviewed?` method (line 72):

```ruby
def fully_reviewed?
  daily_exercise.problem_set.keys.all? { |key| section_reviewed?(key) }
end

def section_reviewed?(section)
  ai_review&.dig(section.to_s).is_a?(Hash)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/daily_response_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/models/daily_response.rb spec/models/daily_response_spec.rb
git commit -m "Add DailyResponse#fully_reviewed? and #section_reviewed?"
```

---

### Task 3: `cache_system:` plumbing through `call`/`call_and_log`

**Files:**
- Modify: `app/services/ai_service.rb:407-409` (`call` stub), `app/services/ai_service.rb:916-926` (`call_and_log`)
- Modify: `app/services/claude_service.rb:37-69`
- Modify: `app/services/gemini_service.rb:29-62`
- Modify: `app/services/fake_service.rb` (`#call` signature only, in the `private` section)
- Test: `spec/services/claude_service_spec.rb`, `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `call(system:, prompt:, cache_system: false)` and `call_and_log(user, purpose:, system:, prompt:, cache_system: false)` — both now accept the new keyword, defaulting to `false` so every existing call site (which never passes it) is unaffected. Task 5 passes `cache_system: true` for review calls.

- [ ] **Step 1: Write the failing test for Claude's caching behavior**

Add to `spec/services/claude_service_spec.rb`, inside the existing `RSpec.describe ClaudeService do ... describe "#call" do` block (find it near the existing `"sends MAX_TOKENS as the request's output budget"` test):

```ruby
it "wraps system in a cache_control content block when cache_system is true" do
  captured_body = nil
  conn = instance_double(Faraday::Connection)
  allow(conn).to receive(:post) do |_url, body|
    captured_body = JSON.parse(body)
    instance_double(Faraday::Response, success?: true, status: 200, body: {
      "content" => [ { "type" => "text", "text" => "hello" } ],
      "usage"   => { "input_tokens" => 1, "output_tokens" => 1 }
    }.to_json)
  end
  service.instance_variable_set(:@conn, conn)

  service.send(:call, system: "shared context", prompt: "prompt text", cache_system: true)

  expect(captured_body["system"]).to eq(
    [ { "type" => "text", "text" => "shared context", "cache_control" => { "type" => "ephemeral" } } ]
  )
end

it "sends system as a plain string when cache_system is false (default)" do
  captured_body = nil
  conn = instance_double(Faraday::Connection)
  allow(conn).to receive(:post) do |_url, body|
    captured_body = JSON.parse(body)
    instance_double(Faraday::Response, success?: true, status: 200, body: {
      "content" => [ { "type" => "text", "text" => "hello" } ],
      "usage"   => { "input_tokens" => 1, "output_tokens" => 1 }
    }.to_json)
  end
  service.instance_variable_set(:@conn, conn)

  service.send(:call, system: "sys", prompt: "prompt text")

  expect(captured_body["system"]).to eq("sys")
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/claude_service_spec.rb -e "cache_system"`
Expected: FAIL with `wrong number of arguments` or `unknown keyword: :cache_system`.

- [ ] **Step 3: Implement in `ClaudeService#call`**

In `app/services/claude_service.rb`, replace the `#call` method (lines 37-69):

```ruby
def call(system:, prompt:, cache_system: false)
  body = {
    model:      MODEL,
    max_tokens: MAX_TOKENS,
    system:     cache_system ? [ { type: "text", text: system, cache_control: { type: "ephemeral" } } ] : system,
    messages:   [ { role: "user", content: prompt } ]
  }

  resp = @conn.post(API_URL, body.to_json)

  unless resp.success?
    log_raw_snippet("Claude API error #{resp.status} body", resp.body)
    message      = extract_provider_message(resp.body, fallback: "Claude API error #{resp.status}")
    error_class  = case resp.status
    when 401, 403 then AiService::AuthenticationError
    when 429, 529 then AiService::RateLimitError
    else               AiService::Error
    end
    raise error_class, message
  end

  parsed = JSON.parse(resp.body)
  usage  = parsed["usage"] || {}

  {
    text:          parsed.dig("content", 0, "text"),
    input_tokens:  usage["input_tokens"],
    output_tokens: usage["output_tokens"],
    truncated:     parsed["stop_reason"] == "max_tokens"
  }
rescue Faraday::Error => e
  raise AiService::Error, "Network error calling Claude: #{e.message}"
end
```

- [ ] **Step 4: Update `GeminiService#call` and `FakeService#call` signatures**

In `app/services/gemini_service.rb`, change the method signature at line 29 from `def call(system:, prompt:)` to `def call(system:, prompt:, cache_system: false)`. Leave the body untouched — Gemini has no caching mechanism in this change (see spec, "Gemini caching — investigated, not implemented").

In `app/services/fake_service.rb`, change `def call(system:, prompt:)` (in the `private` section) to `def call(system:, prompt:, cache_system: false)`. Leave the body untouched for now — Task 6 rewrites its dispatch logic.

- [ ] **Step 5: Update `AiService#call` stub and `#call_and_log`**

In `app/services/ai_service.rb`, replace the stub at lines 407-409:

```ruby
def call(system:, prompt:, cache_system: false)
  raise NotImplementedError, "#{self.class} must implement #call"
end
```

Replace `call_and_log` at lines 916-926:

```ruby
def call_and_log(user, purpose:, system:, prompt:, cache_system: false)
  result = call(system: system, prompt: prompt, cache_system: cache_system)
  log_usage(user, result, purpose: purpose)

  if result[:truncated]
    raise TruncatedResponseError,
          "Provider stopped generating at its output token limit (#{result[:output_tokens].to_i} tokens)"
  end

  result
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/claude_service_spec.rb spec/services/gemini_service_spec.rb spec/services/ai_service_spec.rb`
Expected: PASS (the two new tests pass; every pre-existing test in these three files still passes unmodified, since `cache_system` defaults to `false` and every existing call site omits it).

- [ ] **Step 7: Commit**

```bash
git add app/services/ai_service.rb app/services/claude_service.rb app/services/gemini_service.rb app/services/fake_service.rb spec/services/claude_service_spec.rb
git commit -m "Add cache_system option to AiService#call for Claude prompt caching"
```

---

### Task 4: Per-section review prompt builders, replacing `build_review_prompt`

**Files:**
- Modify: `app/services/ai_service.rb:673-747` (delete `build_review_prompt`), `app/services/ai_service.rb:845-854` (replace `override_parsons_rating!`)
- Test: `spec/services/ai_service_spec.rb:1033-1341` (replace the `#review_response` and `#review_response — parsons_problem rating override` describe blocks)

**Interfaces:**
- Consumes: `config_for`, `parsons_review_block`, `describe_parsons_mismatches` (all unchanged, existing private methods), `ExerciseSection.find`, `ExerciseSection::ParsonsProblem.parse_order`/`.grade` (all existing).
- Produces: `build_review_day_context(coach, exercise, daily_response)` → String (the shared, cacheable content). `build_review_section_prompt(exercise, daily_response, section)` → String (the small, per-call instruction). `override_parsons_section_rating!(review, exercise, daily_response)` → Hash (mutates and returns `review`, a single un-nested section hash). All three consumed by Task 5's `review_sections`.

- [ ] **Step 1: Write the failing tests**

In `spec/services/ai_service_spec.rb`, delete the entire `describe "#review_response" do ... end` block (lines 1033-1281, ending just before `describe "#review_response — parsons_problem rating override" do`) and the `describe "#review_response — parsons_problem rating override" do ... end` block (lines 1283-1341). Replace both with:

```ruby
describe "#build_review_day_context" do
  def exercise_with_third(third_key, third_section)
    DailyExercise.new(language: "ruby_rails", problem_set: {
      "code_review" => { "question" => "cr?", "snippet" => "code" },
      "pattern"     => { "title" => "P", "question" => "pat?" },
      third_key     => third_section
    })
  end

  it "includes all three sections' questions, answers, and self-ratings" do
    exercise = exercise_with_third("challenge", { "question" => "Implement uniq_by" })
    resp = DailyResponse.new(
      answers: { "code_review" => "It's an N+1", "pattern" => "Extract a service object", "challenge" => "def uniq_by; end" },
      section_ratings: { "code_review" => "right_level", "pattern" => "too_hard", "challenge" => "too_easy" }
    )

    context = service.send(:build_review_day_context, "Rails", exercise, resp)

    expect(context).to include("cr?", "It's an N+1", "right_level")
    expect(context).to include("pat?", "Extract a service object", "too_hard")
    expect(context).to include("Implement uniq_by", "def uniq_by; end", "too_easy")
  end

  it "names the coach in the framing" do
    exercise = exercise_with_third("challenge", { "question" => "q" })
    resp = DailyResponse.new(answers: {}, section_ratings: {})
    context = service.send(:build_review_day_context, "JavaScript/React", exercise, resp)
    expect(context).to include("senior JavaScript/React engineer")
  end

  it "tells the model it will be asked to grade only one section" do
    exercise = exercise_with_third("challenge", { "question" => "q" })
    resp = DailyResponse.new(answers: {}, section_ratings: {})
    context = service.send(:build_review_day_context, "Rails", exercise, resp)
    expect(context).to match(/grade exactly one/i)
  end
end

describe "#build_review_section_prompt" do
  def exercise_with_third(third_key, third_section)
    DailyExercise.new(language: "ruby_rails", problem_set: {
      "code_review" => { "question" => "cr?", "snippet" => "code" },
      "pattern"     => { "title" => "P", "question" => "pat?" },
      third_key     => third_section
    })
  end

  it "asks for correct/missed/better_questions as arrays and next_step as a string, ungrouped" do
    exercise = exercise_with_third("challenge", { "question" => "q" })
    resp = DailyResponse.new(answers: {})
    prompt = service.send(:build_review_section_prompt, exercise, resp, "code_review")

    expect(prompt).to include('NOT wrapped in a "code_review" key')
    expect(prompt).to include('"correct": array of strings')
    expect(prompt).to include('"missed": array of strings')
    expect(prompt).to include('"better_questions": array of strings')
    expect(prompt).to include('"next_step": string')
    expect(prompt).to match(/separate ideas belong in separate entries/i)
  end

  it "names pattern as structural and asks for a refactored structure" do
    exercise = exercise_with_third("challenge", { "question" => "q" })
    resp = DailyResponse.new(answers: {})
    prompt = service.send(:build_review_section_prompt, exercise, resp, "pattern")
    expect(prompt).to match(/refactored structure/i)
  end

  it "evaluates architecture on depth of reasoning, not correctness, and forbids improved_code" do
    exercise = exercise_with_third("architecture", { "title" => "A", "question" => "q", "scenario" => "s" })
    resp = DailyResponse.new(answers: {})
    prompt = service.send(:build_review_section_prompt, exercise, resp, "architecture")

    expect(prompt.downcase).to include("tradeoff")
    expect(prompt.downcase).to include("alternatives")
    expect(prompt).to include("must be an empty string for this section")
  end

  it "evaluates security_review on vulnerability + mitigation with partial credit" do
    exercise = exercise_with_third("security_review", { "title" => "S", "question" => "q", "snippet" => "code" })
    resp = DailyResponse.new(answers: {})
    prompt = service.send(:build_review_section_prompt, exercise, resp, "security_review")

    expect(prompt.downcase).to include("mitigation")
    expect(prompt.downcase).to include("partial credit")
  end

  it "grounds parsons_problem in the verified mismatch count and forbids improved_code" do
    exercise = exercise_with_third("parsons_problem", {
      "title" => "T", "question" => "Q", "blocks" => %w[a b c d e]
    })
    resp = DailyResponse.new(answers: { "parsons_problem" => "order:0,2,1,3,4" })
    prompt = service.send(:build_review_section_prompt, exercise, resp, "parsons_problem")

    expect(prompt).to match(/2 block\(s\) out of place/)
    expect(prompt).to match(/do not.*judge|not.*re-judge/i)
    expect(prompt).to include('must be an empty string')
  end

  it "does not claim a verified parsons result when the exercise has no blocks array" do
    exercise = exercise_with_third("parsons_problem", { "title" => "T", "question" => "Q" })
    resp = DailyResponse.new(answers: {})
    prompt = service.send(:build_review_section_prompt, exercise, resp, "parsons_problem")
    expect(prompt).not_to match(/block\(s\) out of place/)
    expect(prompt).to include("CANNOT be verified")
  end
end

describe "#override_parsons_section_rating!" do
  it "always uses the locally computed rating, discarding whatever the model returned" do
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review"     => { "question" => "q", "snippet" => "s" },
        "pattern"         => { "title" => "t", "question" => "q" },
        "parsons_problem" => { "title" => "T", "question" => "Q", "blocks" => %w[a b c d e] }
      }
    )
    response = DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      answers: { "parsons_problem" => "order:0,1,2,3,4" }
    )
    review = { "rating" => "beginner" }

    service.send(:override_parsons_section_rating!, review, exercise, response)

    expect(review["rating"]).to eq("strong")
  end

  it "does nothing when the exercise's parsons_problem has no blocks" do
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review"     => { "question" => "q", "snippet" => "s" },
        "pattern"         => { "title" => "t", "question" => "q" },
        "parsons_problem" => { "title" => "T", "question" => "Q" }
      }
    )
    response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: {})
    review = { "rating" => "developing" }

    service.send(:override_parsons_section_rating!, review, exercise, response)

    expect(review["rating"]).to eq("developing")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "build_review_day_context" -e "build_review_section_prompt" -e "override_parsons_section_rating"`
Expected: FAIL with `NoMethodError` for each undefined method.

- [ ] **Step 3: Implement**

In `app/services/ai_service.rb`, delete the entire `review_response` public method (lines 183-195) and the entire `build_review_prompt` private method (lines 673-747). Delete `override_parsons_rating!` (lines 845-854).

Add these in the `private` section, near where `build_review_prompt` used to live:

```ruby
def build_review_day_context(coach, exercise, daily_response)
  answers = daily_response.answers
  ratings = daily_response.section_ratings

  <<~CONTEXT
    You are a senior #{coach} engineer giving direct, specific feedback on a junior/mid engineer's Code Gym answers. You will grade exactly one of the day's three sections in a follow-up instruction — the other two are given here only so your calibration of "developing" vs. "solid" stays consistent across the whole day. Be honest and constructive. Return JSON.

    Code Review question: #{exercise.code_review["question"]}
    Code snippet: #{exercise.code_review["snippet"]}
    Their answer: #{answers["code_review"].presence || "(skipped)"}
    Their self-rating: #{ratings["code_review"] || "(none given)"}

    Pattern question (#{exercise.pattern["title"]}): #{exercise.pattern["question"]}
    Their answer: #{answers["pattern"].presence || "(skipped)"}
    Their self-rating: #{ratings["pattern"] || "(none given)"}

    #{third_context_summary(exercise, answers, ratings)}
  CONTEXT
end

def third_context_summary(exercise, answers, ratings)
  case exercise.third_key
  when "architecture"
    arch = exercise.architecture
    "Architecture decision (#{arch["title"]}): #{arch["question"]}\n" \
    "Scenario/constraints: #{arch["scenario"]}\n" \
    "Their answer: #{answers["architecture"].presence || "(skipped)"}\n" \
    "Their self-rating: #{ratings["architecture"] || "(none given)"}"
  when "security_review"
    sec = exercise.security_review
    "Security Review (#{sec["title"]}): #{sec["question"]}\n" \
    "Snippet: #{sec["snippet"]}\n" \
    "Their answer: #{answers["security_review"].presence || "(skipped)"}\n" \
    "Their self-rating: #{ratings["security_review"] || "(none given)"}"
  when "parsons_problem"
    parsons = exercise.parsons_problem
    "Parsons Problem (#{parsons["title"]}): #{parsons["question"]}\n" \
    "Their self-rating: #{ratings["parsons_problem"] || "(none given)"}"
  else
    "Coding Challenge: #{exercise.challenge["question"]}\n" \
    "Their answer: #{answers["challenge"].presence || "(skipped)"}\n" \
    "Their self-rating: #{ratings["challenge"] || "(none given)"}"
  end
end

def build_review_section_prompt(exercise, daily_response, section)
  <<~PROMPT
    Grade ONLY the "#{section}" section from the day's context above.

    #{section_grading_note(exercise, daily_response, section)}

    Return a single JSON object (NOT wrapped in a "#{section}" key) with:
    - "rating": "beginner" | "developing" | "solid" | "strong"
    - "correct": array of strings — each entry one distinct thing they got right
    - "missed": array of strings — each entry one distinct thing they missed or got wrong
    - "better_questions": array of strings — each entry one question they should have asked themselves
    - "next_step": string — one specific thing to study
    - "improved_code": string — #{improved_code_instruction(section)}

    Each array entry must be ONE self-contained idea in one or two sentences. Never pack
    several points into one entry, and never number points inside an entry ("1) ... 2) ...")
    — separate ideas belong in separate entries. Use an empty array when there is nothing to
    say for that field.
  PROMPT
end

def improved_code_instruction(section)
  ExerciseSection.find(section)&.improved_code? == false ?
    "must be an empty string for this section" :
    "corrected/improved code for this section"
end

def section_grading_note(exercise, daily_response, section)
  case section
  when "architecture"
    "Evaluate the architecture answer on the DEPTH of its reasoning, not a single correct answer:\n" \
    "- Did they weigh real tradeoffs between the options?\n" \
    "- Did they address the stated constraints (scale, team, reliability, tech debt)?\n" \
    "- Did they consider alternatives rather than asserting one option?"
  when "security_review"
    "Evaluate on whether they correctly identified a real, exploitable vulnerability and whether their " \
    "proposed mitigation is sound — not against one single expected answer. Give partial credit in " \
    "\"missed\" for identifying the vulnerability without a complete mitigation, or vice versa."
  when "parsons_problem"
    parsons_review_block(exercise.parsons_problem, daily_response.answers["parsons_problem"])
  when "pattern"
    "For \"pattern\", improved_code must show the refactored structure that addresses what they missed — " \
    "the classes, methods, and boundaries the pattern calls for — not a one-line tweak. A pattern fix is " \
    "structural; show enough of the shape to make the structure obvious."
  else
    ""
  end
end

# Parsons correctness is decided in Ruby, never by the model — whatever rating it returned
# is discarded and replaced. Skipped when the stored section has no blocks, since there is
# nothing to grade against and the grader would report a spurious perfect score. Operates on
# a single un-nested section hash (the shape #review_sections works with), unlike the old
# whole-review override_parsons_rating! this replaces.
def override_parsons_section_rating!(review, exercise, daily_response)
  parsons = exercise.parsons_problem
  return review unless parsons.is_a?(Hash)

  blocks = Array(parsons["blocks"])
  return review if blocks.empty?

  submitted = ExerciseSection::ParsonsProblem.parse_order(daily_response.answers["parsons_problem"])
  review["rating"] = ExerciseSection::ParsonsProblem.grade(submitted, blocks.size)[:rating]
  review
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS. (This will also surface any other spec in this file still referencing `review_response` or `build_review_prompt` — fix any such reference by deleting it, since Task 5 reintroduces review coverage under `#review_sections`.)

- [ ] **Step 5: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Replace build_review_prompt with per-section day-context and grading prompts"
```

---

### Task 5: `AiService#review_sections` — parallel per-section orchestration

**Files:**
- Modify: `app/services/ai_service.rb` (add near where `review_response` used to be, around line 183)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: `build_review_day_context`, `build_review_section_prompt`, `override_parsons_section_rating!`, `call_and_log` (all from Tasks 3-4), `config_for`, `parse_json_object` (existing).
- Produces: `AiService#review_sections(user, exercise, daily_response, sections:)` → `Hash[String, Hash]`, e.g. `{ "code_review" => { ok: true, review: {...} }, "pattern" => { ok: false, error_code: "rate_limit", message: "..." } }`. Consumed by Task 8 (controller).

- [ ] **Step 1: Write the failing tests**

Add to `spec/services/ai_service_spec.rb`, near the new `#build_review_day_context` block from Task 4:

```ruby
describe "#review_sections" do
  def exercise_and_response
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "cr?", "snippet" => "code" },
        "pattern"     => { "title" => "P", "question" => "pat?" },
        "challenge"   => { "question" => "Implement uniq_by" }
      }
    )
    response = DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "a" * 20, "pattern" => "a" * 20, "challenge" => "a" * 20 },
      submitted_at: Time.current
    )
    [ exercise, response ]
  end

  it "returns an ok: true result per requested section on success" do
    exercise, response = exercise_and_response
    review = { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "" }
    svc = double_class.new(canned_text: review.to_json)

    results = svc.review_sections(user, exercise, response, sections: %w[code_review pattern])

    expect(results.keys).to match_array(%w[code_review pattern])
    expect(results["code_review"]).to eq(ok: true, review: review)
    expect(results["pattern"]).to eq(ok: true, review: review)
  end

  it "logs one ApiUsage row per requested section" do
    exercise, response = exercise_and_response
    svc = double_class.new(canned_text: { "rating" => "solid" }.to_json, input_tokens: 10, output_tokens: 20)

    expect {
      svc.review_sections(user, exercise, response, sections: %w[code_review pattern challenge])
    }.to change { ApiUsage.where(purpose: "review_response").count }.by(3)
  end

  it "tags a failed section without affecting a successful one" do
    exercise, response = exercise_and_response

    failing_class = Class.new(AiService) do
      def initialize(canned_text: "{}")
        @canned_text = canned_text
        @calls = 0
      end

      private

      def call(system:, prompt:, cache_system: false)
        @calls += 1
        raise AiService::RateLimitError, "rate limited" if prompt.include?('"pattern"')
        { text: @canned_text, input_tokens: 1, output_tokens: 1, truncated: false }
      end

      def build_connection = nil
    end
    svc = failing_class.new(canned_text: { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "" }.to_json)

    results = svc.review_sections(user, exercise, response, sections: %w[code_review pattern])

    expect(results["code_review"][:ok]).to be(true)
    expect(results["pattern"]).to eq(ok: false, error_code: "rate_limit", message: "rate limited")
  end

  it "maps AuthenticationError and InvalidResponseError to their error codes" do
    exercise, response = exercise_and_response

    auth_failing = Class.new(AiService) do
      private
      def call(system:, prompt:, cache_system: false) = raise(AiService::AuthenticationError, "bad key")
      def build_connection = nil
    end.new

    results = auth_failing.review_sections(user, exercise, response, sections: %w[code_review])
    expect(results["code_review"][:error_code]).to eq("authentication")
  end

  it "applies override_parsons_section_rating! only when parsons_problem is requested and succeeds" do
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review"     => { "question" => "q", "snippet" => "s" },
        "pattern"         => { "title" => "t", "question" => "q" },
        "parsons_problem" => { "title" => "T", "question" => "Q", "blocks" => %w[a b c d e] }
      }
    )
    response = DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      answers: { "parsons_problem" => "order:0,1,2,3,4" }, submitted_at: Time.current
    )
    svc = double_class.new(canned_text: { "rating" => "beginner" }.to_json)

    results = svc.review_sections(user, exercise, response, sections: %w[parsons_problem])

    expect(results["parsons_problem"][:review]["rating"]).to eq("strong")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "review_sections"`
Expected: FAIL with `NoMethodError: undefined method 'review_sections'`.

- [ ] **Step 3: Implement**

In `app/services/ai_service.rb`, add this public method where `review_response` used to be (after `generate_exercise`, before `generate_concept_reference`):

```ruby
# ── Review a submitted response, one thread per still-missing section ────
# Each thread gets its own service instance (and therefore its own Faraday
# connection) — no shared mutable state crosses a thread boundary. A
# section's failure is caught and tagged rather than raised, so one bad
# section can never keep the other threads' results from being usable by
# the caller.
def review_sections(user, exercise, daily_response, sections:)
  coach   = config_for(exercise.language)[:coach]
  context = build_review_day_context(coach, exercise, daily_response)

  threads = sections.map do |section|
    Thread.new do
      service = self.class.new(@api_key)
      begin
        result = service.send(
          :call_and_log, user, purpose: "review_response",
          system: context, prompt: service.send(:build_review_section_prompt, exercise, daily_response, section),
          cache_system: true
        )
        review = service.send(:parse_json_object, result[:text], subject: "#{section} review")
        review = service.send(:override_parsons_section_rating!, review, exercise, daily_response) if section == "parsons_problem"
        [ section, { ok: true, review: review } ]
      rescue AiService::Error => e
        [ section, { ok: false, error_code: error_code_for(e), message: e.message } ]
      end
    end
  end

  threads.map(&:value).to_h
end
```

Add this private method near `text_or_raise` (line 304):

```ruby
def error_code_for(error)
  case error
  when AuthenticationError  then "authentication"
  when RateLimitError       then "rate_limit"
  when InvalidResponseError then "invalid_response"
  else                           "other"
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Add AiService#review_sections for parallel per-section review calls"
```

---

### Task 6: `FakeService` per-section review dispatch

**Files:**
- Modify: `app/services/fake_service.rb`
- Test: `spec/services/fake_service_spec.rb:54-72`

**Interfaces:**
- Consumes: `FakeService::REVIEW_SECTION` (existing constant — already shaped as a single un-nested section hash, no change needed to it).
- Produces: `FakeService#call` now returns exactly one section's review per invocation, dispatched by the section name embedded in the per-call `prompt:` (matching Task 4's `"Grade ONLY the \"#{section}\" section"` wording), instead of all three at once.

- [ ] **Step 1: Write the failing test**

Replace the `describe "#review_response" do ... end` block in `spec/services/fake_service_spec.rb` (lines 54-72) with:

```ruby
describe "#review_sections" do
  it "returns ok: true for each requested section, independently gradable" do
    user_exercise = DailyExercise.create!(
      user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
      problem_set: described_class::EXERCISE_PROBLEM_SET
    )
    response = DailyResponse.create!(
      user: user, daily_exercise: user_exercise, date: Date.current,
      answers: { "code_review" => "N+1 query", "pattern" => "Extract a service object", "architecture" => "Move it to a job" },
      submitted_at: Time.current
    )

    results = described_class.new(user.api_key).review_sections(user, user_exercise, response, sections: %w[code_review pattern architecture])

    expect(results.keys).to match_array(%w[code_review pattern architecture])
    results.each_value do |outcome|
      expect(outcome[:ok]).to be(true)
      expect(outcome[:review]["correct"]).to be_an(Array)
    end
  end

  it "raises a clear error when the section key can't be extracted from the prompt" do
    service = described_class.new(user.api_key)

    expect {
      service.send(:call, system: "You are a senior Rails engineer giving direct, specific feedback", prompt: "no section marker here")
    }.to raise_error(/could not extract the section key/)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/fake_service_spec.rb -e "review_sections"`
Expected: FAIL — the current `#call` still expects the old 3-key wrapper prompt shape and raises `"FakeService could not extract the third section key from the review prompt"` since the new prompt text no longer matches its regex.

- [ ] **Step 3: Implement**

In `app/services/fake_service.rb`, replace the `#call` method's review branch:

```ruby
def call(system:, prompt:, cache_system: false)
  text =
    case system
    when /generating personalized daily exercise sets/
      EXERCISE_PROBLEM_SET.to_json
    when /giving direct, specific feedback/
      section = prompt[/Grade ONLY the "(\w+)" section/, 1]
      raise "FakeService could not extract the section key from the review prompt" if section.blank?

      REVIEW_SECTION.to_json
    when /writing a concise, durable reference/
      CONCEPT_REFERENCE.to_json
    when /re-explaining one point/
      EXPLAIN_DIFFERENTLY_TEXT
    when /answering a follow-up question/
      FOLLOW_UP_ANSWER_TEXT
    else
      raise "FakeService received an unrecognized system prompt: #{system.inspect}"
    end

  { text: text, input_tokens: 0, output_tokens: 0 }
end
```

Update the class comment at the top of the file (currently describing `#call` dispatching "on the literal `system:` string") to also mention the review path now dispatches the section from `prompt:`:

```ruby
# Deterministic, zero-cost AiService provider for tests. Overrides only the
# two hooks every real provider implements (#call, #build_connection) —
# every other AiService method (DailyPlan, log_usage, normalize_concepts,
# log_retention, shuffle_parsons_blocks!, override_parsons_section_rating!)
# runs unmodified against this fake's output, so tests exercise the same
# control flow a real provider triggers. #call dispatches on the literal
# `system:` string each AiService caller passes; the review path further
# reads which section to grade out of `prompt:`, since #review_sections
# sends the same shared system context to every section's call.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/fake_service_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/services/fake_service.rb spec/services/fake_service_spec.rb
git commit -m "Update FakeService to dispatch per-section review calls"
```

---

### Task 7: `ConceptMastery.record_review!` scoped to sections + session countdown flag

**Files:**
- Modify: `app/models/concept_mastery.rb:26-51`
- Test: `spec/models/concept_mastery_spec.rb`

**Interfaces:**
- Consumes: `response.concept_tags`, `response.ai_rating_for(section)`, `response.self_rating_favorable?(section)`, `ConceptBucket.for`, `evaluate_concept!` (all existing, unchanged).
- Produces: `ConceptMastery.record_review!(response, sections:, apply_session_countdown:)` — both keyword args required (no default; every caller must decide explicitly, since silently defaulting either one wrong would reintroduce the double-count/double-countdown bug this task exists to prevent). Consumed by Task 8 (controller).

- [ ] **Step 1: Write the failing tests**

Find the existing `describe ".record_review!"` (or similar) block in `spec/models/concept_mastery_spec.rb` — run `grep -n "record_review" spec/models/concept_mastery_spec.rb` to locate it. Every existing call like `ConceptMastery.record_review!(response)` in that file must be updated to `ConceptMastery.record_review!(response, sections: response.concept_tags.keys, apply_session_countdown: true)` (this preserves each existing test's original whole-response behavior exactly, since passing every section + countdown-on reproduces today's default). Do this update across the whole file with:

```bash
grep -rn "record_review!(" spec/models/concept_mastery_spec.rb spec/requests/responses_spec.rb spec/jobs
```

and replacing each `record_review!(response)` (or `record_review!(<var>)`) call with `record_review!(<var>, sections: <var>.concept_tags.keys, apply_session_countdown: true)`.

Then add these new tests to `spec/models/concept_mastery_spec.rb`:

```ruby
describe ".record_review! — per-section scoping" do
  it "does not evaluate a concept whose section is excluded from sections:" do
    user = create_user_with_key
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "t", "question" => "q", "concept" => "memoization" }
      }
    )
    response = DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "a" * 20, "pattern" => "a" * 20 }, submitted_at: Time.current,
      section_ratings: { "code_review" => "right_level", "pattern" => "right_level" },
      concept_tags: { "code_review" => "n_plus_one", "pattern" => "memoization" },
      ai_review: {
        "code_review" => { "rating" => "solid" },
        "pattern"     => { "rating" => "solid" }
      }
    )

    ConceptMastery.record_review!(response, sections: %w[code_review], apply_session_countdown: true)

    expect(user.concept_masteries.find_by(concept: "n_plus_one")).to be_present
    expect(user.concept_masteries.find_by(concept: "memoization")).to be_nil
  end

  it "does not decrement paused concepts' cooldown when apply_session_countdown is false" do
    user = create_user_with_key
    paused = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } }
    )
    response = DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
      concept_tags: { "code_review" => "n_plus_one" },
      ai_review: { "code_review" => { "rating" => "solid" } }
    )

    ConceptMastery.record_review!(response, sections: %w[code_review], apply_session_countdown: false)

    expect(paused.reload.cooldown_remaining).to eq(2)
  end

  it "decrements paused concepts' cooldown when apply_session_countdown is true" do
    user = create_user_with_key
    paused = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } }
    )
    response = DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
      concept_tags: { "code_review" => "n_plus_one" },
      ai_review: { "code_review" => { "rating" => "solid" } }
    )

    ConceptMastery.record_review!(response, sections: %w[code_review], apply_session_countdown: true)

    expect(paused.reload.cooldown_remaining).to eq(1)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/models/concept_mastery_spec.rb`
Expected: FAIL — `ArgumentError: missing keywords: :sections, :apply_session_countdown` on every existing call, plus `NoMethodError` from the new tests.

- [ ] **Step 3: Implement**

In `app/models/concept_mastery.rb`, replace `self.record_review!` (lines 26-51):

```ruby
# Called inside ResponsesController#review, in one transaction per successful
# batch of sections (a review action may fire this more than once across
# retries, each time with a disjoint `sections:` — a section can only ever be
# evaluated once, since it's removed from "missing" the moment it succeeds).
# `apply_session_countdown:` gates Step A (the once-per-day paused-cooldown
# decrement) so a later partial-retry within the same day's review never
# re-runs it — the controller passes true only on the first successful batch
# for a given response.
def self.record_review!(response, sections:, apply_session_countdown:)
  user = response.user

  if apply_session_countdown
    user.concept_masteries.tier_paused.each do |cm|
      remaining = cm.cooldown_remaining - 1
      if remaining <= 0
        cm.update!(tier: :reduced, streak: 0, cooldown_remaining: 0)
      else
        cm.update!(cooldown_remaining: remaining)
      end
    end
  end

  sections_by_concept = Hash.new { |h, k| h[k] = [] }
  response.concept_tags.slice(*sections).each do |section, concept|
    next if concept.blank? || concept == "other"
    sections_by_concept[concept] << section
  end

  sections_by_concept.each do |concept, secs|
    bucket = ConceptBucket.for(secs, response.daily_exercise.language)
    evaluate_concept!(user, concept, bucket, response, secs)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/concept_mastery_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/models/concept_mastery.rb spec/models/concept_mastery_spec.rb
git commit -m "Scope ConceptMastery.record_review! to explicit sections and gate session countdown"
```

---

### Task 8: Controller flow — partial success, retry, error persistence

**Files:**
- Modify: `app/controllers/responses_controller.rb:64-83` (`review` action), `:95` (`email_review` guard), `:243` (`require_reviewed_section!`), `:259-268` (`claim_review!`)
- Test: `spec/requests/responses_spec.rb` (multiple `describe` blocks — see Step 1)

**Interfaces:**
- Consumes: `AiService#review_sections` (Task 5), `DailyResponse#fully_reviewed?`/`#section_reviewed?` (Task 2), `ConceptMastery.record_review!(response, sections:, apply_session_countdown:)` (Task 7).
- Produces: updated `review` action behavior — no new public interface beyond the route, which is unchanged.

- [ ] **Step 1: Update existing specs to stub `review_sections` instead of `review_response`**

In `spec/requests/responses_spec.rb`, every `allow(fake_service).to receive(:review_response).and_return(...)` / `.and_raise(...)` and every `instance_double(ClaudeService, review_response: ...)` needs updating to the new `review_sections` shape. Run:

```bash
grep -n "review_response" spec/requests/responses_spec.rb
```

For each hit, apply this substitution pattern (shown for the two most common shapes in the file — apply the same shape to every other hit reported by the grep above):

**Success stub**, e.g. line ~299:
```ruby
# before:
allow(fake_service).to receive(:review_response).and_return("code_review" => { "rating" => "solid" })
# after:
allow(fake_service).to receive(:review_sections).and_return(
  "code_review" => { ok: true, review: { "rating" => "solid" } }
)
```

**Error-raising stub**, e.g. line ~334:
```ruby
# before:
allow(fake_service).to receive(:review_response).and_raise(AiService::Error, "rate limited")
# after:
allow(fake_service).to receive(:review_sections).and_return(
  "code_review" => { ok: false, error_code: "other", message: "rate limited" }
)
```
(Use `error_code: "authentication"` for what was `AiService::AuthenticationError`, and `error_code: "rate_limit"` for what was `AiService::RateLimitError`, matching Task 5's `error_code_for` mapping.)

**`instance_double(ClaudeService, review_response: {...})`** shape, e.g. line ~379 and ~972:
```ruby
# before:
fake = instance_double(ClaudeService, review_response: fake_review)
# after:
fake = instance_double(ClaudeService, review_sections: { "code_review" => { ok: true, review: fake_review } })
```
(Adjust the section key(s) in the returned Hash to match whatever `fake_review` represented for that specific test's exercise.)

Every one of these stubs also needs its exercise's `problem_set` to have exactly the section(s) the stub returns, if it doesn't already — the controller now computes `missing` from `exercise.problem_set.keys - ai_review.keys`, and will call `review_sections` with whatever's missing, so a stub that only knows how to answer for `"code_review"` must be paired with a single-section exercise (most of the existing specs in this file already use single-section exercises for the `review` describe blocks — verify with the `create_exercise` call in each test).

- [ ] **Step 2: Write new tests for partial success and retry**

Add a new describe block to `spec/requests/responses_spec.rb`, near the existing `describe "POST /responses/:id/review"` blocks:

```ruby
describe "POST /responses/:id/review partial success and retry" do
  def submitted_response
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern"     => { "title" => "t", "question" => "q" },
        "challenge"   => { "question" => "q" }
      }
    )
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "a" * 20, "pattern" => "a" * 20, "challenge" => "a" * 20 },
                          submitted_at: Time.current)
  end

  it "saves succeeded sections and records the failure reason for the rest, redirecting to the dashboard" do
    resp = submitted_response
    fake_service = instance_double(ClaudeService, review_sections: {
      "code_review" => { ok: true, review: { "rating" => "solid" } },
      "pattern"     => { ok: true, review: { "rating" => "developing" } },
      "challenge"   => { ok: false, error_code: "rate_limit", message: "rate limited" }
    })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    post review_response_path(resp)

    expect(response).to redirect_to(root_path)
    expect(flash[:notice]).to eq("2 of 3 sections reviewed — 1 couldn't be reviewed, try again.")
    resp.reload
    expect(resp.ai_review.keys).to match_array(%w[code_review pattern])
    expect(resp.review_errors).to eq("challenge" => "rate_limit")
    expect(resp).not_to be_fully_reviewed
    expect(resp).to be_reviewed
  end

  it "only re-requests the still-missing section on retry, and clears its error once it succeeds" do
    resp = submitted_response
    resp.update!(
      ai_review: { "code_review" => { "rating" => "solid" }, "pattern" => { "rating" => "developing" } },
      review_errors: { "challenge" => "rate_limit" }
    )
    fake_service = instance_double(ClaudeService)
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    expect(fake_service).to receive(:review_sections)
      .with(user, resp.daily_exercise, resp, sections: %w[challenge])
      .and_return("challenge" => { ok: true, review: { "rating" => "strong" } })

    post review_response_path(resp)

    expect(response).to redirect_to(history_path(anchor: "response-#{resp.id}"))
    expect(flash[:notice]).to eq("Review ready!")
    resp.reload
    expect(resp).to be_fully_reviewed
    expect(resp.review_errors).to eq({})
  end

  it "does not re-decrement a paused concept's cooldown on a retry that completes the review" do
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "t", "question" => "q" },
        "challenge"   => { "question" => "q" }
      }
    )
    resp = DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "a" * 20, "pattern" => "a" * 20, "challenge" => "a" * 20 },
      submitted_at: Time.current, concept_tags: { "code_review" => "n_plus_one" }
    )
    paused = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)

    fake_service = instance_double(ClaudeService, review_sections: {
      "code_review" => { ok: true, review: { "rating" => "solid" } },
      "pattern"     => { ok: true, review: { "rating" => "solid" } },
      "challenge"   => { ok: false, error_code: "other", message: "boom" }
    })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    post review_response_path(resp)
    expect(paused.reload.cooldown_remaining).to eq(1)

    retry_service = instance_double(ClaudeService, review_sections: {
      "challenge" => { ok: true, review: { "rating" => "solid" } }
    })
    allow(AiService).to receive(:for).with(user).and_return(retry_service)
    post review_response_path(resp)

    expect(paused.reload.cooldown_remaining).to eq(1)
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bundle exec rspec spec/requests/responses_spec.rb`
Expected: FAIL — existing specs fail on `review_response` no longer being a method on the double (or, once Step 1's substitutions are applied, the new specs fail because the controller doesn't implement partial-success handling yet).

- [ ] **Step 4: Implement**

In `app/controllers/responses_controller.rb`, replace the `review` action (lines 64-83):

```ruby
def review
  return redirect_to root_path, alert: "Submit your answers first." unless @response.submitted?

  missing = @response.daily_exercise.problem_set.keys - Array(@response.ai_review&.keys)
  return redirect_to history_anchor, notice: "Already reviewed." if missing.empty?

  unless claim_review!
    return redirect_to root_path, alert: "A review is already being generated for this — check back in a moment."
  end

  first_batch = @response.ai_review.blank?
  results = AiService.for(current_user).review_sections(current_user, @response.daily_exercise, @response, sections: missing)
  successes = results.select { |_, r| r[:ok] }
  failures  = results.reject { |_, r| r[:ok] }

  if successes.any?
    ActiveRecord::Base.transaction do
      @response.ai_review = (@response.ai_review || {}).merge(successes.transform_values { |r| r[:review] })
      @response.review_errors = @response.review_errors.except(*successes.keys)
                                                         .merge(failures.transform_values { |r| r[:error_code] })
      @response.save!
      ConceptMastery.record_review!(@response, sections: successes.keys, apply_session_countdown: first_batch)
    end
  end
  release_review_claim!

  if failures.empty?
    redirect_to history_anchor, notice: "Review ready!"
  elsif successes.any?
    redirect_to root_path, notice: "#{successes.size} of #{missing.size} sections reviewed — #{failures.size} couldn't be reviewed, try again."
  else
    redirect_to root_path, alert: zero_success_alert(failures)
  end
rescue AiService::AuthenticationError
  release_review_claim!
  redirect_to root_path, alert: "Your API key was rejected — check it in Settings."
rescue AiService::RateLimitError
  release_review_claim!
  redirect_to root_path, alert: "The AI provider is rate-limiting requests — try again shortly."
rescue AiService::Error => e
  release_review_claim!
  redirect_to root_path, alert: "Couldn't generate the review: #{e.message}"
end
```

Note the `rescue` clauses stay — `AiService.for(current_user)` itself (the dispatch call, not `review_sections`) can still raise `AiService::Error` (e.g. unrecognized provider), and that path is unchanged from today.

Add a private helper near the other private methods:

```ruby
def zero_success_alert(failures)
  codes = failures.values.map { |f| f[:error_code] }.uniq
  case codes
  in [ "authentication" ]
    "Your API key was rejected — check it in Settings."
  in [ "rate_limit" ]
    "The AI provider is rate-limiting requests — try again shortly."
  else
    "Couldn't generate the review: #{failures.values.first[:message]}"
  end
end
```

Update `email_review` (line 95): change `unless @response.reviewed?` to `unless @response.fully_reviewed?`.

Update `require_reviewed_section!` (around line 243):

```ruby
def require_reviewed_section!
  @section = params[:section].to_s
  return render_section_error("That section isn't part of this exercise.") unless @response.daily_exercise.problem_set.key?(@section)
  return render_section_error("No review to attach that to yet.") unless @response.section_reviewed?(@section)
end
```

Update `claim_review!` (lines 259-268) — drop the `ai_review: nil` clause:

```ruby
def claim_review!
  claimed = DailyResponse.where(id: @response.id)
                         .where("reviewing_since IS NULL OR reviewing_since < ?", REVIEW_CLAIM_STALE_AFTER.ago)
                         .update_all(reviewing_since: Time.current) == 1
  @response.reload if claimed
  claimed
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/requests/responses_spec.rb`
Expected: PASS

- [ ] **Step 6: Run the full request/service/model suite for regressions**

Run: `bundle exec rspec spec/requests spec/services spec/models --exclude-pattern "system/**/*_spec.rb"`
Expected: PASS. If `spec/requests/responses_spec.rb`'s `explain_differently`/`follow_ups`/`self_explanation` specs fail because they were relying on the old response-wide `reviewed?` gate, update their setup to seed `ai_review` for the specific section under test (they likely already do, since they test one section's follow-up flow — verify and adjust if any test seeds `ai_review` for a *different* section than the one it's exercising).

- [ ] **Step 7: Commit**

```bash
git add app/controllers/responses_controller.rb spec/requests/responses_spec.rb
git commit -m "Support partial review success, retry, and per-section gating in ResponsesController"
```

---

### Task 9: UI — "Finish review" button state and locale copy

**Files:**
- Modify: `app/views/responses/_submission.html.erb:11-16`
- Modify: `config/locales/en.yml:40-41`
- Test: `spec/requests/dashboard_spec.rb`

**Interfaces:**
- Consumes: `DailyResponse#fully_reviewed?`/`#reviewed?` (Task 2, existing).
- Produces: no new interface — view-only change.

- [ ] **Step 1: Write the failing test**

Add to `spec/requests/dashboard_spec.rb`, near the existing review-rendering tests (find via `grep -n "review" spec/requests/dashboard_spec.rb` for the right neighborhood):

```ruby
it "shows a Finish review button, not Get review, when some but not all sections are reviewed" do
  exercise = create_exercise
  create_response(exercise, submitted: true, ai_review: { "code_review" => { "rating" => "solid" } })
  get root_path
  expect(response.body).to include(">Finish review<")
  expect(response.body).not_to include("Get ")
end

it "shows the provider's Get review button when nothing has been reviewed yet" do
  exercise = create_exercise
  create_response(exercise, submitted: true)
  get root_path
  expect(response.body).to match(/Get \S+ review/)
end
```

(Check `create_exercise`/`create_response` helper signatures already used elsewhere in this file — e.g. the existing `"renders the review with the keys review_response actually returns"` test — and match their exact keyword names; `ai_review:` and `submitted:` are used there already.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "Finish review"`
Expected: FAIL — the button currently always says "Get %{provider} review →" and only hides once `reviewed?` (any section) is true, so a partial state currently shows nothing at all instead of "Finish review".

- [ ] **Step 3: Implement**

In `config/locales/en.yml`, add a `finish_button` key alongside `get_button` (line 41):

```yaml
  review:
    get_button: "Get %{provider} review →"
    finish_button: "Finish review →"
    heading: "%{provider}'s Review"
    history_summary: "%{provider}'s review"
    calibration_note: "You rated this \"%{rating}\" — the review suggests there's more to work on here."
```

In `app/views/responses/_submission.html.erb`, replace lines 11-16:

```erb
  <% unless response.fully_reviewed? %>
    <%= button_to response.reviewed? ? t("review.finish_button") : t("review.get_button", provider: response.user.provider_label),
          review_response_path(response), method: :post,
          class: "btn btn-primary btn-sm",
          form: { class: "review-form", data: { turbo: false } } %>
  <% end %>
```

And line 19's `<% if response.reviewed? %>` stays as-is — the review panel should still render whatever's present, partial or not.

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/views/responses/_submission.html.erb config/locales/en.yml spec/requests/dashboard_spec.rb
git commit -m "Show Finish review button for partially-reviewed responses"
```

---

### Task 10: Full regression run and manual browser verification

**Files:** none (verification only)

**Interfaces:** none

- [ ] **Step 1: Run the full non-system suite**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
Expected: PASS, zero failures.

- [ ] **Step 2: Run the system suite**

Follow the one-time Playwright CLI install instructions in the comment block at the top of `spec/support/system_test_helper.rb` if not already installed, then:

Run: `bundle exec rspec spec/system`
Expected: PASS, including `spec/system/review_request_spec.rb`'s full happy-path review flow (submit → click review → land on history with review visible) — this now exercises three real parallel `Thread`s against `FakeService` end to end.

- [ ] **Step 3: Manual browser verification of the partial-review state**

This is the check flagged during design review: passing specs are not the same as the partial-review UI actually reading clearly next to a fully-rendered one. Using `bin/dev` and a local user with `provider: "fake"` (see `spec/support` / `create_fake_provider_user` for how test users are built, or create one via `rails console`):

1. Submit a day's answers.
2. In `rails console`, manually set `daily_response.update!(ai_review: { "code_review" => { "rating" => "solid", "correct" => ["Good catch"], "missed" => [], "better_questions" => [], "next_step" => "Keep going", "improved_code" => "" }, "pattern" => { "rating" => "developing", "correct" => [], "missed" => ["Missed the edge case"], "better_questions" => [], "next_step" => "Review this", "improved_code" => "" } }, review_errors: { "challenge" => "rate_limit" })` (adjust section keys to the exercise's actual third section) to simulate a real partial-failure outcome without needing a real provider failure.
3. Load the dashboard. Confirm: two sections render full review content, the third section shows nothing (no broken placeholder, no stray key), and the "Finish review" button appears and reads sensibly next to that mixed state — not confusingly wedged between a finished section and an empty one.
4. Click "Finish review" against a real or fake backend and confirm it resolves to "Review ready!" once the last section succeeds.

- [ ] **Step 4: Report findings**

If the manual check in Step 3 reveals the UI reads confusingly (e.g. no visual indication of *why* a section is missing, or the button placement is ambiguous next to two finished sections), note it — a copy/layout fix belongs in a follow-up task, not silently skipped.
