# Regenerate Button + Multi-Provider (Anthropic/Gemini) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users manually regenerate today's exercise set (capped once/day) and bring either an Anthropic or a Google Gemini API key, auto-detected from the key's prefix.

**Architecture:** Extract a provider-agnostic `AiService` base class from today's `ClaudeService` (prompts, concept vocabulary, JSON parsing, usage logging). `ClaudeService` and a new `GeminiService` subclass it, each owning only their provider's HTTP request/response shape. An `AiService.for(user)` factory dispatches on a new `User#provider` column (detected from the key's prefix at save time). The regenerate button is a new controller action that reuses `AiService.for` to refresh today's `DailyExercise` row in place.

**Tech Stack:** Rails 8.0.5, RSpec (request/model/service specs, no HTTP-stubbing gem — Faraday connections are stubbed via `instance_double`/`instance_variable_set` at the Ruby object level, matching the existing test style), Faraday + faraday-retry (already in `Gemfile`), PostgreSQL/jsonb.

## Global Constraints

- No changes to magic-link auth, Resend/SMTP, or the `/test_login` route.
- No changes to concept tagging, teaching notes, or the feedback UI.
- `provider` is a real column on `User` (not reused from any jsonb field) — validated `inclusion: { in: %w[anthropic gemini] }, allow_nil: true`.
- `AiService::Error` replaces `ClaudeService::Error` as the one rescuable error class at every call site.
- GeminiService uses Gemini's Interactions API (`POST https://generativelanguage.googleapis.com/v1beta/interactions`, header `x-goog-api-key`, model `gemini-3.5-flash`, `store: false`) — verified against `ai.google.dev/gemini-api/docs/get-started` and `ai.google.dev/gemini-api/docs/interactions-overview`. Do not use Gemini's native `response_format`/JSON-schema structured output — both providers rely on the same prompt-embedded `EXERCISE_SCHEMA` text plus `parse_json_response`'s markdown-fence-stripping fallback.
- `DailyExercise` is unique per `user_id` + `date` (existing DB constraint) — regeneration always updates today's row in place, never creates a second row.
- Every provider's `#call(system:, prompt:)` returns a normalized `Hash` — `{ text:, input_tokens:, output_tokens: }` — with symbol keys. No other code reads a provider's raw response envelope.

---

## Task 1: Extract `AiService` base class from `ClaudeService`

**Files:**
- Create: `app/services/ai_service.rb`
- Modify: `app/services/claude_service.rb`
- Create: `spec/services/ai_service_spec.rb`
- Modify: `spec/services/claude_service_spec.rb`

**Interfaces:**
- Produces: `AiService::Error`, `AiService::CONCEPTS`, `AiService::RATING_LABELS`, `AiService::EXERCISE_SCHEMA`, `AiService#generate_exercise(user)`, `AiService#review_response(user, exercise, daily_response)`, private `AiService#call(system:, prompt:)` (subclass hook, must return `{ text:, input_tokens:, output_tokens: }`), private `AiService#build_connection` (subclass hook), private `AiService#build_exercise_prompt(user)`, `#build_review_prompt(exercise, daily_response)`, `#normalize_concepts(problem_set)`, `#parse_json_response(text)`, `#log_usage(user, result, purpose:)`.
- `ClaudeService < AiService` keeps `ClaudeService::MODEL`, `ClaudeService::API_URL`.

- [ ] **Step 1: Update `spec/services/claude_service_spec.rb` to expect the shared error class (RED)**

Replace the whole file:

```ruby
require "rails_helper"

RSpec.describe ClaudeService do
  let(:service) { described_class.new("sk-ant-test") }

  describe "#build_connection" do
    it "sets Anthropic auth headers" do
      conn = service.send(:build_connection)
      expect(conn.headers["x-api-key"]).to eq("sk-ant-test")
      expect(conn.headers["anthropic-version"]).to eq("2023-06-01")
    end
  end

  describe "#call" do
    it "posts the Anthropic-shaped request body and normalizes the response" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "content" => [ { "type" => "text", "text" => "hello" } ],
          "usage"   => { "input_tokens" => 10, "output_tokens" => 20 }
        }.to_json)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |url, body|
        expect(url).to eq(ClaudeService::API_URL)
        parsed = JSON.parse(body)
        expect(parsed["model"]).to eq(ClaudeService::MODEL)
        expect(parsed["system"]).to eq("sys")
        expect(parsed["messages"]).to eq([ { "role" => "user", "content" => "prompt text" } ])
        fake_response
      end

      result = service.send(:call, system: "sys", prompt: "prompt text")
      expect(result).to eq(text: "hello", input_tokens: 10, output_tokens: 20)
    end

    it "raises AiService::Error on a non-success response" do
      fake_response = instance_double(Faraday::Response, success?: false, status: 500, body: "boom")
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error, /Claude API error 500/)
    end
  end
end
```

- [ ] **Step 2: Create `spec/services/ai_service_spec.rb` covering the shared logic (RED)**

```ruby
require "rails_helper"

RSpec.describe AiService do
  let(:user) { User.create!(email: "prompt@example.com", name: "Prompt") }

  # Minimal concrete subclass so AiService's shared logic can be exercised
  # without a real network call to any provider.
  let(:double_class) do
    Class.new(AiService) do
      def initialize(canned_text: "{}", input_tokens: 1, output_tokens: 1)
        @canned_text   = canned_text
        @input_tokens  = input_tokens
        @output_tokens = output_tokens
      end

      private

      def call(system:, prompt:)
        { text: @canned_text, input_tokens: @input_tokens, output_tokens: @output_tokens }
      end

      def build_connection
        nil
      end
    end
  end

  let(:service) { double_class.new }

  describe "EXERCISE_SCHEMA" do
    it "defines a teaching_note and a concept for each of the three sections" do
      expect(AiService::EXERCISE_SCHEMA.scan('"teaching_note"').size).to eq(3)
      expect(AiService::EXERCISE_SCHEMA.scan('"concept"').size).to eq(3)
    end
  end

  describe "CONCEPTS" do
    it "is a frozen 16-entry vocabulary" do
      expect(AiService::CONCEPTS.size).to eq(16)
      expect(AiService::CONCEPTS).to be_frozen
      expect(AiService::CONCEPTS).to include("n_plus_one", "transaction_safety", "error_handling")
    end
  end

  describe "#build_exercise_prompt" do
    it "instructs that teaching notes hint without giving the answer" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("teaching_note")
      expect(prompt.downcase).to include("never the full answer")
    end

    it "embeds the vocabulary, the mastery loop, and per-session concepts with correct rating labels" do
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :too_hard,
                            concept_tags: { "code_review" => "n_plus_one" })

      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include(AiService::CONCEPTS.join(", "))
      expect(prompt).to include("mastery signal")
      expect(prompt).to include("concepts: n_plus_one")
      expect(prompt).to include("too hard")
      expect(prompt).not_to include("unrated")
    end
  end

  describe "#normalize_concepts" do
    it "raises AiService::Error for valid JSON that is not an object" do
      expect {
        service.send(:normalize_concepts, [ "not", "a", "problem set" ])
      }.to raise_error(AiService::Error, /Array instead of a JSON object/)
    end

    it "keeps on-list concepts and maps off-list ones to 'other'" do
      set = {
        "code_review" => { "concept" => "n_plus_one" },
        "pattern" => { "concept" => "N+1 Queries!!" },
        "challenge" => { "question" => "no concept key" }
      }
      out = service.send(:normalize_concepts, set)
      expect(out["code_review"]["concept"]).to eq("n_plus_one")
      expect(out["pattern"]["concept"]).to eq("other")
      expect(out["challenge"]).not_to have_key("concept")
    end
  end

  describe "#parse_json_response" do
    it "strips markdown fences before parsing" do
      fenced = "```json\n{\"a\":1}\n```"
      expect(service.send(:parse_json_response, fenced)).to eq("a" => 1)
    end

    it "raises AiService::Error for invalid JSON" do
      expect {
        service.send(:parse_json_response, "not json")
      }.to raise_error(AiService::Error, /invalid JSON/)
    end
  end

  describe "#generate_exercise" do
    it "logs usage and normalizes concepts from the provider's response" do
      set = { "code_review" => { "concept" => "bogus" } }
      svc = double_class.new(canned_text: set.to_json, input_tokens: 5, output_tokens: 7)

      result = svc.generate_exercise(user)

      expect(result["code_review"]["concept"]).to eq("other")
      usage = ApiUsage.last
      expect(usage.tokens_in).to eq(5)
      expect(usage.tokens_out).to eq(7)
      expect(usage.purpose).to eq("generate_exercise")
    end
  end
end
```

- [ ] **Step 3: Run both spec files to verify they fail**

Run: `bundle exec rspec spec/services/claude_service_spec.rb spec/services/ai_service_spec.rb`
Expected: FAIL — `uninitialized constant AiService` (ai_service.rb doesn't exist yet; claude_service_spec references `AiService::Error` which doesn't exist).

- [ ] **Step 4: Create `app/services/ai_service.rb`**

```ruby
require "json"

class AiService
  class Error < StandardError; end

  # Fixed concept vocabulary. Embedded in the generation prompt; anything a
  # provider returns outside this list is normalized to "other" so per-user
  # concept history stays aggregatable.
  CONCEPTS = %w[
    n_plus_one transaction_safety memoization service_objects scope_chaining
    idempotency authorization background_jobs caching validations
    callbacks_vs_service query_objects policy_objects indexing concurrency
    error_handling
  ].freeze

  RATING_LABELS = { "too_easy" => "too easy", "right_level" => "right level", "too_hard" => "too hard" }.freeze

  # JSON schema every provider is asked to return for a problem set
  EXERCISE_SCHEMA = <<~SCHEMA
    {
      "code_review": {
        "question": "string — what to find/fix",
        "snippet":  "string — Ruby/Rails code, ~10-15 lines",
        "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
        "concept": "string — exactly one concept from the provided vocabulary"
      },
      "pattern": {
        "title":    "string — pattern name",
        "why":      "string — one sentence on why the pattern exists",
        "question": "string — conceptual question to answer",
        "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
        "concept": "string — exactly one concept from the provided vocabulary",
        "reference": {
          "tagline":      "string — bold one-liner",
          "explanation":  "string — 2-3 sentences",
          "code_example": "string — annotated Ruby, ~15 lines",
          "senior_lens":  "string — when to reach for it / tradeoffs"
        }
      },
      "challenge": {
        "title":        "string",
        "question":     "string — what to implement",
        "starter_code": "string — optional skeleton (empty string if none)",
        "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
        "concept": "string — exactly one concept from the provided vocabulary"
      }
    }
  SCHEMA

  def initialize(api_key)
    @api_key = api_key
    @conn    = build_connection
  end

  # ── Dispatch to the right provider for this user ─────────────────────────
  def self.for(user)
    case user.provider
    when "anthropic" then ClaudeService.new(user.api_key)
    when "gemini"    then GeminiService.new(user.api_key)
    else
      raise Error, "User #{user.id} has no recognized AI provider configured"
    end
  end

  # ── Generate a personalized daily exercise set ────────────────────────────
  def generate_exercise(user)
    result = call(system: build_system_prompt, prompt: build_exercise_prompt(user))

    log_usage(user, result, purpose: "generate_exercise")
    normalize_concepts(parse_json_response(result[:text]))
  end

  # ── Review a submitted response inline ───────────────────────────────────
  def review_response(user, exercise, daily_response)
    result = call(
      system: "You are a senior Rails engineer giving direct, specific feedback on a junior/mid engineer's Code Gym answers. Be honest and constructive. Return JSON.",
      prompt: build_review_prompt(exercise, daily_response)
    )

    log_usage(user, result, purpose: "review_response")
    parse_json_response(result[:text])
  end

  private

  # Subclasses must implement: makes the provider-specific HTTP call and
  # returns a normalized Hash { text:, input_tokens:, output_tokens: }.
  def call(system:, prompt:)
    raise NotImplementedError, "#{self.class} must implement #call"
  end

  # Subclasses must implement: returns a configured Faraday::Connection.
  def build_connection
    raise NotImplementedError, "#{self.class} must implement #build_connection"
  end

  def build_system_prompt
    <<~PROMPT
      You are a senior Rails engineering coach generating personalized daily exercise sets.
      Your goal is to push engineers toward senior-level thinking: not just "what" but "why" and "when not to."
      Focus on real Rails patterns: N+1 queries, idempotency, background jobs, authorization, service objects, query objects, policy objects.
      Return ONLY valid JSON — no markdown fences, no explanation outside the JSON.
    PROMPT
  end

  def build_exercise_prompt(user)
    history = user.recent_performance(days: 10)

    history_text = if history.empty?
      "No history yet — this is their first exercise set."
    else
      history.map { |h|
        rating_label = RATING_LABELS[h[:rating]] || "unrated"
        feedback     = h[:feedback].present? ? " | Feedback: \"#{h[:feedback]}\"" : ""
        concepts     = h[:concepts].respond_to?(:values) ? h[:concepts].values.compact.uniq : []
        concept_text = concepts.any? ? " | concepts: #{concepts.join(', ')}" : ""
        "#{h[:date]}: #{h[:sections_answered]}/3 sections answered | #{rating_label}#{concept_text}#{feedback}"
      }.join("\n")
    end

    focus = user.focus_areas.any? ? user.focus_areas.join(", ") : "general Rails patterns"

    <<~PROMPT
      Generate a daily Code Gym exercise set for this engineer.

      Engineer profile:
      - Name: #{user.name}
      - Skill level: #{user.skill_level} (beginner → developing → solid → strong)
      - Priority focus areas: #{focus}

      Recent performance (last 10 sessions):
      #{history_text}

      Instructions:
      - If they've been rating exercises "too easy", increase difficulty and reduce explanation in the reference.
      - If they've been rating "too hard" or skipping sections, simplify and add more scaffolding.
      - Prioritize focus areas they've missed or rated hard recently.
      - The code_review snippet must be realistic Rails code — not toy examples.
      - The challenge starter_code should give enough scaffold to get started without giving away the answer.
      - Rotate between topics across sessions — avoid the same pattern two days in a row.
      - Each teaching_note must point toward how to think about the problem or the right question to ask — one or two sentences, never the full answer.
      - Choose each section's concept from this fixed vocabulary, exactly one per section: #{CONCEPTS.join(", ")}
      - Mastery loop: for any concept whose most recent rating was "too hard", reintroduce that concept in this set with a different code example and framing — same underlying concept, never a repeat of the same snippet. Keep reintroducing it in every subsequent set until the user rates a set containing it "right level" or "too easy"; that rating is the mastery signal that ends reinforcement for that concept.
      - Concepts most recently rated "too easy" must not repeat within the same week.
      - Concepts most recently rated "right level" have no special weighting.

      Return JSON matching this schema exactly:
      #{EXERCISE_SCHEMA}
    PROMPT
  end

  def build_review_prompt(exercise, daily_response)
    answers = daily_response.answers

    <<~PROMPT
      Review these Code Gym answers. For each section, return a JSON object with:
      - "rating": "beginner" | "developing" | "solid" | "strong"
      - "correct": string — what they got right
      - "missed": string — what they missed or got wrong
      - "better_questions": string — questions they should have asked themselves
      - "next_step": string — one specific thing to study
      - "improved_code": string — corrected/improved code (for code sections only; empty string otherwise)

      Exercise:
      Code Review question: #{exercise.code_review["question"]}
      Code snippet: #{exercise.code_review["snippet"]}
      Their answer: #{answers["code_review"].presence || "(skipped)"}

      Pattern question (#{exercise.pattern["title"]}): #{exercise.pattern["question"]}
      Their answer: #{answers["pattern"].presence || "(skipped)"}

      Coding Challenge: #{exercise.challenge["question"]}
      Their answer: #{answers["challenge"].presence || "(skipped)"}

      Return JSON with keys: "code_review", "pattern", "challenge" — each matching the schema above.
    PROMPT
  end

  def parse_json_response(text)
    # Strip any accidental markdown fences
    clean = text.to_s.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip
    JSON.parse(clean)
  rescue JSON::ParserError => e
    raise Error, "Provider returned invalid JSON: #{e.message}\n\nRaw: #{text}"
  end

  # A provider occasionally invents tags; keep the vocabulary closed so
  # aggregation over concept history stays clean.
  def normalize_concepts(problem_set)
    unless problem_set.is_a?(Hash)
      raise Error, "Provider returned #{problem_set.class} instead of a JSON object for the problem set"
    end

    problem_set.each_value do |section|
      next unless section.is_a?(Hash) && section.key?("concept")
      section["concept"] = "other" unless CONCEPTS.include?(section["concept"])
    end
    problem_set
  end

  def log_usage(user, result, purpose:)
    ApiUsage.create!(
      user:       user,
      tokens_in:  result[:input_tokens].to_i,
      tokens_out: result[:output_tokens].to_i,
      purpose:    purpose,
      date:       Date.current
    )
  rescue => e
    Rails.logger.warn("ApiUsage log failed: #{e.message}")
  end
end
```

- [ ] **Step 5: Replace `app/services/claude_service.rb` with the Anthropic-only subclass**

```ruby
require "faraday"
require "faraday/retry"

class ClaudeService < AiService
  MODEL   = "claude-sonnet-4-5"
  API_URL = "https://api.anthropic.com/v1/messages"

  private

  def call(system:, prompt:)
    body = {
      model:      MODEL,
      max_tokens: 2500,
      system:     system,
      messages:   [ { role: "user", content: prompt } ]
    }

    resp = @conn.post(API_URL, body.to_json)

    raise AiService::Error, "Claude API error #{resp.status}: #{resp.body}" unless resp.success?

    parsed = JSON.parse(resp.body)
    usage  = parsed["usage"] || {}

    {
      text:          parsed.dig("content", 0, "text"),
      input_tokens:  usage["input_tokens"],
      output_tokens: usage["output_tokens"]
    }
  rescue Faraday::Error => e
    raise AiService::Error, "Network error calling Claude: #{e.message}"
  end

  def build_connection
    Faraday.new do |f|
      f.headers["x-api-key"]         = @api_key
      f.headers["anthropic-version"] = "2023-06-01"
      f.headers["content-type"]      = "application/json"
      f.request :retry, max: 2, interval: 1, retry_statuses: [ 529 ]
      f.adapter :net_http
    end
  end
end
```

- [ ] **Step 6: Run both spec files to verify they pass**

Run: `bundle exec rspec spec/services/claude_service_spec.rb spec/services/ai_service_spec.rb`
Expected: PASS (all examples green).

- [ ] **Step 7: Commit**

```bash
git add app/services/ai_service.rb app/services/claude_service.rb spec/services/ai_service_spec.rb spec/services/claude_service_spec.rb
git commit -m "Extract AiService base class from ClaudeService"
```

---

## Task 2: Add `provider` column to `User`

**Files:**
- Create: `db/migrate/20260712010000_add_provider_to_users.rb`
- Modify: `app/models/user.rb`
- Modify: `spec/models/user_spec.rb`

**Interfaces:**
- Produces: `users.provider` column (string, nullable), `User` validates `provider` inclusion in `%w[anthropic gemini]` allowing nil.

- [ ] **Step 1: Write the failing model spec**

Add to `spec/models/user_spec.rb`, inside the existing `describe "validations"` block (after the `"downcases email before saving"` test):

```ruby
    it "allows a nil provider" do
      user = User.new(email: "dev@example.com", name: "Dev", provider: nil)
      expect(user).to be_valid
    end

    it "accepts anthropic or gemini as the provider" do
      expect(User.new(email: "a@example.com", name: "A", provider: "anthropic")).to be_valid
      expect(User.new(email: "b@example.com", name: "B", provider: "gemini")).to be_valid
    end

    it "rejects an unrecognized provider" do
      user = User.new(email: "c@example.com", name: "C", provider: "openai")
      expect(user).not_to be_valid
      expect(user.errors[:provider]).to be_present
    end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/models/user_spec.rb`
Expected: FAIL — `unknown attribute 'provider' for User` (column doesn't exist yet).

- [ ] **Step 3: Create the migration**

```ruby
# Detected from the API key's prefix at save time (see ApiKeysController) —
# lets AiService.for dispatch to the right provider service without a
# separate settings UI. Nullable: nil until the user has saved a key.
class AddProviderToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :provider, :string
  end
end
```

- [ ] **Step 4: Run the migration**

Run: `bin/rails db:migrate`
Expected: `== AddProviderToUsers: migrating ==` ... `== AddProviderToUsers: migrated`. Confirm `db/schema.rb` now has `t.string "provider"` under `create_table "users"`.

- [ ] **Step 5: Add the validation to `app/models/user.rb`**

```ruby
  validates :skill_level, inclusion: { in: %w[beginner developing solid strong] }
  validates :provider, inclusion: { in: %w[anthropic gemini] }, allow_nil: true
```

(insert the new line directly after the existing `validates :skill_level` line)

- [ ] **Step 6: Run the spec to verify it passes**

Run: `bundle exec rspec spec/models/user_spec.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260712010000_add_provider_to_users.rb db/schema.rb app/models/user.rb spec/models/user_spec.rb
git commit -m "Add provider column to User"
```

---

## Task 3: Detect provider from key prefix in `ApiKeysController`

**Files:**
- Modify: `app/controllers/api_keys_controller.rb`
- Modify: `app/views/api_keys/edit.html.erb`
- Modify: `spec/requests/api_keys_spec.rb`
- Modify: `spec/support/auth_helpers.rb`

**Interfaces:**
- Produces: `ApiKeysController::PROVIDER_PATTERNS` (Hash of provider name => Regexp), used only within this controller.

- [ ] **Step 1: Write the failing request specs**

Replace `spec/requests/api_keys_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "ApiKeys", type: :request do
  let(:user) { User.create!(email: "dev@example.com", name: "Dev") }

  def login(user)
    get verify_auth_path(token: user.generate_login_token!)
  end

  describe "PATCH /setup" do
    it "saves a valid Anthropic key, encrypted, and detects the provider" do
      login(user)

      patch setup_path, params: { api_key: "sk-ant-api03-abc123" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.api_key).to eq("sk-ant-api03-abc123")
      expect(user.provider).to eq("anthropic")
      expect(user.api_key_present?).to be true
    end

    it "saves a valid Gemini key and detects the provider" do
      login(user)

      patch setup_path, params: { api_key: "AIzaSyExampleKey12345" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.api_key).to eq("AIzaSyExampleKey12345")
      expect(user.provider).to eq("gemini")
    end

    it "rejects a key that doesn't look like either provider's key" do
      login(user)

      patch setup_path, params: { api_key: "not-a-real-key" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("We don't recognize this key format — currently supporting Anthropic and Gemini keys.")
      expect(user.reload.api_key_present?).to be false
      expect(user.provider).to be_nil
    end
  end
end
```

- [ ] **Step 2: Update `spec/support/auth_helpers.rb` to set a provider**

```ruby
module AuthHelpers
  def create_user_with_key(email: "dev@example.com", name: "Dev")
    user = User.create!(email: email, name: name)
    user.update!(api_key: "sk-ant-test-key", provider: "anthropic")
    user
  end

  def login_as(user)
    get verify_auth_path(token: user.generate_login_token!)
  end
end

RSpec.configure do |config|
  config.include AuthHelpers, type: :request
end
```

- [ ] **Step 3: Run the specs to verify they fail**

Run: `bundle exec rspec spec/requests/api_keys_spec.rb`
Expected: FAIL — Gemini key test fails because the controller still only accepts `sk-ant-` keys; error-message test fails because the copy is still the old Anthropic-only message.

- [ ] **Step 4: Update `app/controllers/api_keys_controller.rb`**

```ruby
class ApiKeysController < ApplicationController
  skip_before_action :require_api_key

  PROVIDER_PATTERNS = {
    "anthropic" => /\Ask-ant-/,
    "gemini"    => /\AAIza/
  }.freeze

  # GET /setup
  def edit; end

  # PATCH /setup
  def update
    key      = params[:api_key].to_s.strip
    provider = PROVIDER_PATTERNS.find { |_, pattern| key.match?(pattern) }&.first

    unless provider
      flash.now[:alert] = "We don't recognize this key format — currently supporting Anthropic and Gemini keys."
      render :edit, status: :unprocessable_entity
      return
    end

    current_user.update!(api_key: key, provider: provider)
    redirect_to root_path, notice: "API key saved. You're all set!"
  end
end
```

- [ ] **Step 5: Update the setup view copy in `app/views/api_keys/edit.html.erb`**

Replace the `<p>` and hint text (find-and-replace, keep the surrounding markup/styles exactly as-is):

```erb
  <p>Your key is encrypted at rest and only used to generate your personal exercise sets and reviews. Usage is tracked per-user for transparency.</p>

  <%= form_with url: setup_path, method: :patch do |f| %>
    <div class="form-field">
      <%= f.label :api_key, "API key" %>
      <%= f.password_field :api_key, placeholder: "sk-ant-... or AIza...", autocomplete: "off" %>
      <p class="hint">Paste an Anthropic key (<a href="https://console.anthropic.com/settings/keys" target="_blank">console.anthropic.com</a>, starts with <code>sk-ant-</code>) or a Google Gemini key (<a href="https://aistudio.google.com/apikey" target="_blank">aistudio.google.com</a>, starts with <code>AIza</code>).</p>
    </div>
    <%= f.submit "Save key →", class: "btn btn-primary" %>
  <% end %>
```

- [ ] **Step 6: Run the specs to verify they pass**

Run: `bundle exec rspec spec/requests/api_keys_spec.rb`
Expected: PASS.

- [ ] **Step 7: Run the full suite to confirm the `auth_helpers.rb` change didn't break other request specs**

Run: `bundle exec rspec spec/requests`
Expected: PASS (all previously-passing request specs remain green — `create_user_with_key` still returns a valid, logged-in-able user).

- [ ] **Step 8: Commit**

```bash
git add app/controllers/api_keys_controller.rb app/views/api_keys/edit.html.erb spec/requests/api_keys_spec.rb spec/support/auth_helpers.rb
git commit -m "Detect AI provider from API key prefix"
```

---

## Task 4: Backfill `provider` for existing users

**Files:**
- Create: `db/migrate/20260712020000_backfill_user_provider.rb`
- Create: `spec/migrations/backfill_user_provider_spec.rb`

**Interfaces:**
- Consumes: `User#api_key` (decrypts transparently), `User#provider` (from Task 2).
- Produces: nothing consumed by later tasks — this is a one-off data migration.

- [ ] **Step 1: Write the failing migration spec**

```ruby
require "rails_helper"

migration_path = Rails.root.join("db/migrate/20260712020000_backfill_user_provider.rb")
require migration_path.to_s

RSpec.describe BackfillUserProvider do
  it "backfills provider from an Anthropic-shaped key" do
    user = User.create!(email: "legacy@example.com", name: "Legacy")
    user.update!(api_key: "sk-ant-legacy-key")

    described_class.new.up

    expect(user.reload.provider).to eq("anthropic")
  end

  it "backfills provider from a Gemini-shaped key" do
    user = User.create!(email: "legacy-gemini@example.com", name: "Legacy Gemini")
    user.update!(api_key: "AIzaSyLegacyKey123")

    described_class.new.up

    expect(user.reload.provider).to eq("gemini")
  end

  it "leaves provider nil and logs a warning for an unrecognized key" do
    user = User.create!(email: "legacy-unknown@example.com", name: "Legacy Unknown")
    user.update!(api_key: "totally-unknown-format")

    expect(Rails.logger).to receive(:warn).with(/unrecognized key format/)
    described_class.new.up

    expect(user.reload.provider).to be_nil
  end

  it "skips users with no api_key set" do
    user = User.create!(email: "no-key@example.com", name: "No Key")

    expect { described_class.new.up }.not_to raise_error
    expect(user.reload.provider).to be_nil
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/migrations/backfill_user_provider_spec.rb`
Expected: FAIL — `LoadError` / `cannot load such file` (migration file doesn't exist yet).

- [ ] **Step 3: Create the migration**

```ruby
# One-off data migration: existing users already saved an encrypted API key
# under the old Anthropic-only validation, but we derive `provider` the same
# way ApiKeysController does going forward, in case any non-Anthropic-shaped
# key ever slipped through.
class BackfillUserProvider < ActiveRecord::Migration[8.0]
  def up
    User.where.not(api_key: nil).find_each do |user|
      key = user.api_key # decrypts transparently via `encrypts :api_key`
      provider =
        case key
        when /\Ask-ant-/ then "anthropic"
        when /\AAIza/    then "gemini"
        end

      if provider
        user.update_column(:provider, provider)
      else
        Rails.logger.warn("BackfillUserProvider: unrecognized key format for user #{user.id}")
      end
    end
  end

  def down
    # no-op — reverting the provider column (added in a separate migration)
    # is sufficient; there's no prior state to restore.
  end
end
```

- [ ] **Step 4: Run the migration for real**

Run: `bin/rails db:migrate`
Expected: `== BackfillUserProvider: migrating ==` ... `== BackfillUserProvider: migrated`.

- [ ] **Step 5: Run the spec to verify it passes**

Run: `bundle exec rspec spec/migrations/backfill_user_provider_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260712020000_backfill_user_provider.rb db/schema.rb spec/migrations/backfill_user_provider_spec.rb
git commit -m "Backfill provider for existing users"
```

---

## Task 5: Add `GeminiService`

**Files:**
- Create: `app/services/gemini_service.rb`
- Create: `spec/services/gemini_service_spec.rb`

**Interfaces:**
- Consumes: `AiService` (Task 1) — subclasses it, implements `#call(system:, prompt:)` and `#build_connection`.
- Produces: `GeminiService::MODEL`, `GeminiService::API_URL`, used by `AiService.for` (already wired in Task 1's `self.for`).

- [ ] **Step 1: Write the failing spec**

```ruby
require "rails_helper"

RSpec.describe GeminiService do
  let(:service) { described_class.new("AIzaTestKey") }

  describe "#build_connection" do
    it "sets the Gemini auth header" do
      conn = service.send(:build_connection)
      expect(conn.headers["x-goog-api-key"]).to eq("AIzaTestKey")
    end
  end

  describe "#call" do
    it "posts the Gemini-shaped request body and extracts text + usage from the model_output step" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "steps" => [
            { "type" => "thought" },
            { "type" => "model_output", "content" => [ { "type" => "text", "text" => "hello" } ] }
          ],
          "usage" => { "total_input_tokens" => 8, "total_output_tokens" => 12 }
        }.to_json)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |url, body|
        expect(url).to eq(GeminiService::API_URL)
        parsed = JSON.parse(body)
        expect(parsed["model"]).to eq(GeminiService::MODEL)
        expect(parsed["system_instruction"]).to eq("sys")
        expect(parsed["input"]).to eq("prompt text")
        expect(parsed["store"]).to eq(false)
        fake_response
      end

      result = service.send(:call, system: "sys", prompt: "prompt text")
      expect(result).to eq(text: "hello", input_tokens: 8, output_tokens: 12)
    end

    it "raises AiService::Error on a non-success response" do
      fake_response = instance_double(Faraday::Response, success?: false, status: 503, body: "overloaded")
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error, /Gemini API error 503/)
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/services/gemini_service_spec.rb`
Expected: FAIL — `uninitialized constant GeminiService`.

- [ ] **Step 3: Create `app/services/gemini_service.rb`**

```ruby
require "faraday"
require "faraday/retry"

class GeminiService < AiService
  MODEL   = "gemini-3.5-flash"
  API_URL = "https://generativelanguage.googleapis.com/v1beta/interactions"

  private

  def call(system:, prompt:)
    body = {
      model:              MODEL,
      system_instruction: system,
      input:              prompt,
      store:              false
    }

    resp = @conn.post(API_URL, body.to_json)

    raise AiService::Error, "Gemini API error #{resp.status}: #{resp.body}" unless resp.success?

    parsed       = JSON.parse(resp.body)
    model_output = Array(parsed["steps"]).find { |s| s["type"] == "model_output" }
    text_parts   = Array(model_output && model_output["content"]).select { |c| c["type"] == "text" }.map { |c| c["text"] }
    usage        = parsed["usage"] || {}

    {
      text:          text_parts.join,
      input_tokens:  usage["total_input_tokens"],
      output_tokens: usage["total_output_tokens"]
    }
  rescue Faraday::Error => e
    raise AiService::Error, "Network error calling Gemini: #{e.message}"
  end

  def build_connection
    Faraday.new do |f|
      f.headers["x-goog-api-key"] = @api_key
      f.headers["content-type"]   = "application/json"
      f.request :retry, max: 2, interval: 1, retry_statuses: [ 429, 503 ]
      f.adapter :net_http
    end
  end
end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/services/gemini_service_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/gemini_service.rb spec/services/gemini_service_spec.rb
git commit -m "Add GeminiService"
```

---

## Task 6: `AiService.for` factory spec coverage

`AiService.for` was already implemented in Task 1 (it needs to exist before `ClaudeService`/`GeminiService` load-order concerns matter, and Zeitwerk resolves both subclass constants lazily at call time). This task only adds the dispatch-behavior spec now that both subclasses exist.

**Files:**
- Modify: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: `AiService.for(user)` (Task 1), `ClaudeService` (Task 1), `GeminiService` (Task 5), `User#provider` (Task 2).

- [ ] **Step 1: Write the failing spec**

Add to `spec/services/ai_service_spec.rb`, as a new top-level `describe` block after the existing `describe "#generate_exercise"` block:

```ruby
  describe ".for" do
    it "returns a ClaudeService for an anthropic user" do
      user.update!(api_key: "sk-ant-test", provider: "anthropic")
      expect(AiService.for(user)).to be_a(ClaudeService)
    end

    it "returns a GeminiService for a gemini user" do
      user.update!(api_key: "AIzaTest", provider: "gemini")
      expect(AiService.for(user)).to be_a(GeminiService)
    end

    it "raises AiService::Error when the user has no recognized provider" do
      expect { AiService.for(user) }.to raise_error(AiService::Error, /no recognized AI provider/)
    end
  end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: FAIL if `self.for` were missing — but since it was added in Task 1, run this first to confirm; if it unexpectedly fails, that indicates Task 1's `self.for` implementation has a bug to fix before continuing.

- [ ] **Step 3: Run the spec to verify it passes**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add spec/services/ai_service_spec.rb
git commit -m "Add AiService.for dispatch spec coverage"
```

---

## Task 7: Swap call sites to `AiService.for`

**Files:**
- Modify: `app/jobs/generate_daily_exercises_job.rb`
- Modify: `app/controllers/responses_controller.rb`
- Create: `spec/jobs/generate_daily_exercises_job_spec.rb`
- Modify: `spec/requests/responses_spec.rb`

**Interfaces:**
- Consumes: `AiService.for(user)`, `AiService::Error` (Task 1).

- [ ] **Step 1: Write the failing job spec**

```ruby
require "rails_helper"

RSpec.describe GenerateDailyExercisesJob do
  let(:user) { User.create!(email: "cronuser@example.com", name: "Cron", provider: "anthropic", api_key: "sk-ant-test") }

  it "creates a DailyExercise from the provider's generated problem set" do
    fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    described_class.new.perform(user_id: user.id)

    exercise = DailyExercise.find_by(user: user, date: Date.current)
    expect(exercise.problem_set).to eq("code_review" => {})
  end

  it "logs and continues when AiService::Error is raised" do
    fake_service = instance_double(ClaudeService)
    allow(fake_service).to receive(:generate_exercise).and_raise(AiService::Error, "boom")
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    expect(Rails.logger).to receive(:error).with(/Failed to generate exercise.*boom/)
    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
    expect(DailyExercise.exists?(user: user, date: Date.current)).to be false
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/jobs/generate_daily_exercises_job_spec.rb`
Expected: FAIL — `#<InstanceDouble(AiService) (anonymous)> received :for` unexpected message, because the job still calls `ClaudeService.new(user.api_key)` directly, never `AiService.for`.

- [ ] **Step 3: Update `app/jobs/generate_daily_exercises_job.rb`**

```ruby
class GenerateDailyExercisesJob < ApplicationJob
  queue_as :default

  # Called two ways:
  #   1. Cron (no args) — generates for ALL users at 8am weekdays
  #   2. On-demand (user_id:) — generates for one user when they first open the app
  def perform(user_id: nil)
    users = user_id ? User.where(id: user_id) : User.where.not(api_key: nil)

    users.find_each do |user|
      next if DailyExercise.exists?(user: user, date: Date.current)

      generate_for(user)
    end
  end

  private

  def generate_for(user)
    problem_set = AiService.for(user).generate_exercise(user)

    DailyExercise.create!(
      user:         user,
      date:         Date.current,
      problem_set:  problem_set,
      generated_at: Time.current
    )

    Rails.logger.info("Generated exercise for #{user.email} on #{Date.current}")
  rescue AiService::Error => e
    Rails.logger.error("Failed to generate exercise for #{user.email}: #{e.message}")
    # Don't re-raise — one failure shouldn't block other users in the batch
  end
end
```

- [ ] **Step 4: Run the job spec to verify it passes**

Run: `bundle exec rspec spec/jobs/generate_daily_exercises_job_spec.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing request spec for `ResponsesController#review`**

Add to `spec/requests/responses_spec.rb`, as a new top-level `describe` block (after the existing `describe "POST /responses/:id/email_review"` block, before the final `end`):

```ruby
  describe "POST /responses/:id/review" do
    def create_submitted_response
      exercise = DailyExercise.create!(
        user: user, date: Date.current,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" },
                       "pattern" => { "title" => "t", "question" => "q" },
                       "challenge" => { "title" => "t", "question" => "q" } },
        generated_at: Time.current
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
    end

    it "saves the ai_review from the user's configured provider" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_return("code_review" => { "rating" => "solid" })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(response).to redirect_to(root_path)
      expect(daily_response.reload.ai_review).to eq("code_review" => { "rating" => "solid" })
    end

    it "redirects with an alert when the provider raises" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_raise(AiService::Error, "rate limited")
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("Couldn't generate the review: rate limited")
    end
  end
```

- [ ] **Step 6: Run the spec to verify it fails**

Run: `bundle exec rspec spec/requests/responses_spec.rb`
Expected: FAIL — the first new example fails because `ResponsesController#review` still calls `ClaudeService.new` directly (so the `AiService.for` stub is never hit and the real, unstubbed `ClaudeService#review_response` would attempt a real network call using the test API key, raising a Faraday connection error rather than returning the stubbed review).

- [ ] **Step 7: Update `app/controllers/responses_controller.rb`**

```ruby
  # POST /responses/:id/review — trigger inline Claude review
  def review
    return redirect_to root_path, alert: "Submit your answers first." unless @response.submitted?
    return redirect_to root_path, notice: "Already reviewed." if @response.reviewed?

    ai_review = AiService.for(current_user).review_response(current_user, @response.daily_exercise, @response)

    @response.update!(ai_review: ai_review)
    redirect_to root_path, notice: "Review ready!"
  rescue AiService::Error => e
    redirect_to root_path, alert: "Couldn't generate the review: #{e.message}"
  end
```

(replace only this method; the rest of `responses_controller.rb` — `create`, `feedback`, `email_review`, and the `private` section — is unchanged)

- [ ] **Step 8: Run the spec to verify it passes**

Run: `bundle exec rspec spec/requests/responses_spec.rb`
Expected: PASS.

- [ ] **Step 9: Run the full suite to confirm nothing else regressed**

Run: `bundle exec rspec`
Expected: PASS (all examples green).

- [ ] **Step 10: Commit**

```bash
git add app/jobs/generate_daily_exercises_job.rb app/controllers/responses_controller.rb spec/jobs/generate_daily_exercises_job_spec.rb spec/requests/responses_spec.rb
git commit -m "Route job and review action through AiService.for"
```

---

## Task 8: Regenerate button

**Files:**
- Create: `db/migrate/20260712030000_add_regenerated_at_to_daily_exercises.rb`
- Create: `app/controllers/daily_exercises_controller.rb`
- Modify: `config/routes.rb`
- Modify: `app/views/dashboard/show.html.erb`
- Create: `spec/requests/daily_exercises_spec.rb`
- Modify: `spec/requests/dashboard_spec.rb`

**Interfaces:**
- Consumes: `AiService.for(user)`, `AiService::Error` (Task 1), `DailyExercise#daily_response` (existing `has_one`), `regenerate_path` route helper.
- Produces: `daily_exercises.regenerated_at` column, `DailyExercisesController#regenerate`.

- [ ] **Step 1: Write the failing request specs for the new endpoint**

```ruby
require "rails_helper"

RSpec.describe "DailyExercises", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  def create_exercise(regenerated_at: nil)
    DailyExercise.create!(user: user, date: Date.current,
                          problem_set: { "code_review" => { "question" => "old" } },
                          generated_at: Time.current, regenerated_at: regenerated_at)
  end

  describe "POST /regenerate" do
    it "redirects with an alert when there's no exercise yet" do
      post regenerate_path
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("No exercise set to regenerate yet.")
    end

    it "replaces the problem_set, sets regenerated_at, and destroys the existing response" do
      exercise = create_exercise
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 })

      fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => { "question" => "new" } })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post regenerate_path

      exercise.reload
      expect(exercise.problem_set).to eq("code_review" => { "question" => "new" })
      expect(exercise.regenerated_at).to be_present
      expect(exercise.daily_response).to be_nil
      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq("New set generated!")
    end

    it "blocks a second regeneration the same day" do
      create_exercise(regenerated_at: Time.current)

      post regenerate_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("You've already generated a new set today.")
    end

    it "redirects with an alert when the provider raises" do
      exercise = create_exercise
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:generate_exercise).and_raise(AiService::Error, "rate limited")
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post regenerate_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("Couldn't generate a new set: rate limited")
      expect(exercise.reload.regenerated_at).to be_nil
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/requests/daily_exercises_spec.rb`
Expected: FAIL — `undefined method 'regenerate_path'` (route doesn't exist yet).

- [ ] **Step 3: Create the migration**

```ruby
# Tracks whether today's exercise set has already been manually regenerated
# via the dashboard "Generate new set" button (separate from the 8am cron).
# DailyExercise is unique per user_id + date, so this naturally resets to nil
# every day without any extra bookkeeping.
class AddRegeneratedAtToDailyExercises < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_exercises, :regenerated_at, :datetime
  end
end
```

- [ ] **Step 4: Run the migration**

Run: `bin/rails db:migrate`
Expected: `== AddRegeneratedAtToDailyExercises: migrating ==` ... `== AddRegeneratedAtToDailyExercises: migrated`. Confirm `db/schema.rb` now has `t.datetime "regenerated_at"` under `create_table "daily_exercises"`.

- [ ] **Step 5: Add the route**

In `config/routes.rb`, add this line directly after the `get "history", to: "history#index"` line:

```ruby
  # Manually re-run today's exercise generation (capped at once/day in the controller)
  post "regenerate", to: "daily_exercises#regenerate"
```

- [ ] **Step 6: Create `app/controllers/daily_exercises_controller.rb`**

```ruby
class DailyExercisesController < ApplicationController
  # POST /regenerate — manually re-run today's exercise generation, capped
  # at once per day via regenerated_at. Replaces the existing DailyExercise
  # row's contents in place; never creates a second row for the same day.
  def regenerate
    exercise = current_user.daily_exercises.for_date.first
    return redirect_to root_path, alert: "No exercise set to regenerate yet." unless exercise

    if exercise.regenerated_at.present?
      return redirect_to root_path, alert: "You've already generated a new set today."
    end

    exercise.daily_response&.destroy

    problem_set = AiService.for(current_user).generate_exercise(current_user)
    exercise.update!(
      problem_set:    problem_set,
      generated_at:   Time.current,
      regenerated_at: Time.current
    )

    redirect_to root_path, notice: "New set generated!"
  rescue AiService::Error => e
    redirect_to root_path, alert: "Couldn't generate a new set: #{e.message}"
  end
end
```

- [ ] **Step 7: Run the spec to verify it passes**

Run: `bundle exec rspec spec/requests/daily_exercises_spec.rb`
Expected: PASS.

- [ ] **Step 8: Write the failing dashboard view specs**

Add to `spec/requests/dashboard_spec.rb`, as a new top-level `describe` block (after the existing `describe "teaching hints"` block, before the final `end`):

```ruby
  describe "regenerate button" do
    it "shows a light confirm when there are no answers yet" do
      create_exercise
      get root_path
      expect(response.body).to include("Generate new set")
      expect(response.body).to include("Generate a new set for today?")
    end

    it "shows a strong warning once the user has draft or submitted answers" do
      create_response(create_exercise)
      get root_path
      expect(response.body).to include("erase your answers so far")
    end

    it "shows the already-regenerated message once capped, and hides the button" do
      exercise = create_exercise
      exercise.update!(regenerated_at: Time.current)
      get root_path
      expect(response.body).to include("You've already generated a new set today.")
      expect(response.body).not_to include("Generate new set")
    end
  end
```

- [ ] **Step 9: Run the spec to verify it fails**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: FAIL — the dashboard view has no regenerate button/messages yet, so none of the three new examples find the expected text.

- [ ] **Step 10: Add the button to `app/views/dashboard/show.html.erb`**

Find this block:

```erb
<% else %>
  <% submitted = @response.persisted? && @response.submitted? %>

  <%# Progress bar (only shown before submission; sticky so progress stays
```

Replace it with (inserting the new regenerate block between the `submitted` line and the progress-bar comment):

```erb
<% else %>
  <% submitted = @response.persisted? && @response.submitted? %>

  <div class="regenerate-row" style="margin-bottom:1.5rem;">
    <% if @exercise.regenerated_at.present? %>
      <p class="hint">You've already generated a new set today.</p>
    <% else %>
      <% has_progress = @response.persisted? && (@response.submitted? || @response.answers.values.any?(&:present?)) %>
      <% confirm_msg = has_progress ?
           "This will replace today's problems and erase your answers so far. This can't be undone. Continue?" :
           "Generate a new set for today?" %>
      <%= button_to "Generate new set", regenerate_path, method: :post,
            class: "btn btn-ghost btn-sm", data: { turbo_confirm: confirm_msg } %>
    <% end %>
  </div>

  <%# Progress bar (only shown before submission; sticky so progress stays
```

- [ ] **Step 11: Run the spec to verify it passes**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: PASS.

- [ ] **Step 12: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS (all examples green, no regressions across the whole suite).

- [ ] **Step 13: Commit**

```bash
git add db/migrate/20260712030000_add_regenerated_at_to_daily_exercises.rb db/schema.rb config/routes.rb app/controllers/daily_exercises_controller.rb app/views/dashboard/show.html.erb spec/requests/daily_exercises_spec.rb spec/requests/dashboard_spec.rb
git commit -m "Add regenerate button with contextual confirmation, capped once/day"
```
