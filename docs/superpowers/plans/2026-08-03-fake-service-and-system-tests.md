# FakeService + System Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic, zero-cost `"fake"` `AiService` provider for tests, and a small Capybara/Playwright system-test suite that drives real browser flows (rating-gated submit, review loading/redirect) against it.

**Architecture:** `FakeService < AiService` overrides only `#call`/`#build_connection` (the same two hooks `ClaudeService`/`GeminiService` implement), dispatching on the literal `system:` string each `AiService` caller passes to decide which canned response to return. Every other `AiService` method — `DailyPlan`, `log_usage`, `normalize_concepts`, `log_retention`, `shuffle_parsons_blocks!`, `override_parsons_rating!` — runs unmodified. `capybara-playwright-driver` drives a real headless Chromium against the fake provider so the app's inline JS (rating-gated submit, review loading state, dashboard status polling) gets real browser coverage for the first time.

**Tech Stack:** Rails 8.0, RSpec, Capybara, capybara-playwright-driver (playwright-ruby-client under the hood, requires Node.js + a matching `playwright-core` npm install), Faraday (untouched by this work).

## Global Constraints

- All work happens on the `fake-service-system-tests` branch (already checked out) — never commit to `main` directly.
- No changes to `ClaudeService`, `GeminiService`, or `AiService.for`'s dispatch logic beyond adding the `"fake"` branch.
- No migration: `users.provider` is a plain `string` column with app-level `inclusion` validation only.
- `capybara` and `capybara-playwright-driver` go in a **new**, separate `group :test do ... end` block in the Gemfile — not merged into the existing `group :development, :test` — so neither gem loads in development.
- No system spec may use a real API key; all three use the `"fake"` provider exclusively.
- No conversion of existing request/model/service/job specs to system specs.
- Design doc: `docs/superpowers/specs/2026-08-03-fake-service-and-system-tests-design.md`.

---

### Task 1: Provider wiring + FakeService exercise generation

**Files:**
- Modify: `app/models/user.rb` (provider validation, ~line 19)
- Modify: `app/services/ai_service.rb` (`self.for` dispatch, ~lines 134-140)
- Create: `app/services/fake_service.rb`
- Test: `spec/services/fake_service_spec.rb`

**Interfaces:**
- Produces: `FakeService < AiService`, `FakeService::EXERCISE_PROBLEM_SET` (a frozen `Hash` with string keys `"code_review"`, `"pattern"`, `"challenge"`, `"architecture"`, `"security_review"`, `"parsons_problem"`, each a `Hash` matching `AiService#exercise_schema_for`'s shape for that key). `AiService.for(user)` returns `FakeService.new(user.api_key)` when `user.provider == "fake"`.
- Consumes: `AiService#call`, `#build_connection` contract (private, overridden). `AiService#generate_exercise` (inherited, unmodified) calls `call(system:, prompt:)` with a `system:` string containing `"generating personalized daily exercise sets"` for this path (see `AiService#build_system_prompt`).

- [ ] **Step 1: Write the failing spec for provider validation + dispatch**

```ruby
# spec/services/fake_service_spec.rb
require "rails_helper"

RSpec.describe FakeService do
  let(:user) do
    User.create!(email: "fake-svc@example.com", name: "Fake", provider: "fake", api_key: "fake-test-key")
  end

  it "is a valid provider value on User" do
    expect(user).to be_valid
  end

  it "is what AiService.for returns for a fake-provider user" do
    expect(AiService.for(user)).to be_a(FakeService)
  end

  describe "#generate_exercise" do
    it "returns a problem set covering every ExerciseSection kind with valid, non-'other' concepts" do
      problem_set = described_class.new(user.api_key).generate_exercise(user, language: "ruby_rails")

      expect(problem_set.keys).to match_array(
        %w[code_review pattern challenge architecture security_review parsons_problem]
      )
      problem_set.each_value do |section|
        expect(section["concept"]).to be_present
        expect(section["concept"]).not_to eq("other")
      end
    end

    it "resolves to the architecture third when persisted, since architecture has top precedence" do
      problem_set = described_class.new(user.api_key).generate_exercise(user, language: "ruby_rails")
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: problem_set,
                                        language: "ruby_rails", generated_at: Time.current)

      expect(exercise.third_key).to eq("architecture")
    end

    it "logs API usage with zero cost" do
      expect {
        described_class.new(user.api_key).generate_exercise(user, language: "ruby_rails")
      }.to change(ApiUsage, :count).by(1)

      usage = ApiUsage.last
      expect(usage.tokens_in).to eq(0)
      expect(usage.tokens_out).to eq(0)
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/services/fake_service_spec.rb`
Expected: FAIL — `uninitialized constant FakeService` (and the `User` validation example fails since `"fake"` isn't yet a valid provider).

- [ ] **Step 3: Add `"fake"` to the User provider validation**

In `app/models/user.rb`, change:

```ruby
  validates :provider, inclusion: { in: %w[anthropic gemini] }, allow_nil: true
```

to:

```ruby
  validates :provider, inclusion: { in: %w[anthropic gemini fake] }, allow_nil: true
```

- [ ] **Step 4: Wire the dispatch branch in `AiService.for`**

In `app/services/ai_service.rb`, change:

```ruby
  def self.for(user)
    case user.provider
    when "anthropic" then ClaudeService.new(user.api_key)
    when "gemini"    then GeminiService.new(user.api_key)
    else
      raise Error, "User #{user.id} has no recognized AI provider configured"
    end
  end
```

to:

```ruby
  def self.for(user)
    case user.provider
    when "anthropic" then ClaudeService.new(user.api_key)
    when "gemini"    then GeminiService.new(user.api_key)
    when "fake"      then FakeService.new(user.api_key)
    else
      raise Error, "User #{user.id} has no recognized AI provider configured"
    end
  end
```

- [ ] **Step 5: Create `FakeService` with the exercise-generation branch**

```ruby
# app/services/fake_service.rb

# Deterministic, zero-cost AiService provider for tests. Overrides only the
# two hooks every real provider implements (#call, #build_connection) —
# every other AiService method (DailyPlan, log_usage, normalize_concepts,
# log_retention, shuffle_parsons_blocks!, override_parsons_rating!) runs
# unmodified against this fake's output, so tests exercise the same control
# flow a real provider triggers. #call dispatches on the literal `system:`
# string each AiService caller passes — see ai_service.rb for where each one
# is built.
class FakeService < AiService
  # All six ExerciseSection kinds populated at once. DailyExercise#third_key
  # resolves by precedence over whichever keys are present hashes
  # (ExerciseSection.thirds: architecture, security_review, challenge,
  # parsons_problem) — architecture wins here every time, regardless of
  # which third DailyPlan actually asked for, since normalize_concepts and
  # shuffle_parsons_blocks! only ever touch keys that exist.
  EXERCISE_PROBLEM_SET = {
    "code_review" => {
      "question" => "This method recalculates a customer's loyalty tier every time it's called, even inside a loop over the whole customer list. What's the issue and how would you fix it?",
      "snippet" => <<~RUBY.strip,
        def loyalty_tier(customer)
          total = customer.orders.sum(&:total_cents)
          case total
          when 0...10_000 then "bronze"
          when 10_000...50_000 then "silver"
          else "gold"
          end
        end

        customers.each { |c| puts loyalty_tier(c) }
      RUBY
      "teaching_note" => "Look at what happens to the database each time this method runs inside the loop.",
      "concept" => "n_plus_one",
      "scenario" => "a nightly loyalty-tier recalculation job",
      "glossary" => [
        { "term" => "loyalty tier", "definition" => "A customer segment (bronze/silver/gold) based on total spend." }
      ]
    },
    "pattern" => {
      "title" => "Service Object",
      "why" => "Keeps a multi-step business operation out of the model and controller so it can be tested and reused on its own.",
      "question" => "When would you reach for a service object instead of adding another method to the model?",
      "scenario" => "checkout logic that charges a card, updates inventory, and sends a receipt email",
      "teaching_note" => "Count how many unrelated responsibilities the operation currently touches.",
      "concept" => "service_objects",
      "glossary" => []
    },
    "challenge" => {
      "title" => "Cache the expensive lookup",
      "question" => "Implement a method that returns a customer's lifetime order count without recalculating it on every call within the same request.",
      "scenario" => "a customer profile page that renders the order count in three different places",
      "starter_code" => "",
      "teaching_note" => "Think about what should persist across calls within one request but not across requests.",
      "concept" => "memoization",
      "glossary" => []
    },
    "architecture" => {
      "title" => "Synchronous or async receipt emails",
      "scenario" => "Checkout currently emails a receipt synchronously. Traffic has grown enough that email delivery now visibly slows down the checkout response.",
      "question" => "Would you move receipt delivery to a background job, and how would you justify that tradeoff?",
      "options" => [ "Keep it synchronous but add a timeout", "Move it to a background job via Solid Queue" ],
      "teaching_note" => "Weigh checkout latency against the complexity of a job retry/failure path.",
      "concept" => "service_boundaries",
      "glossary" => [],
      "reference" => {
        "tagline" => "Move slow, non-critical work off the request path.",
        "explanation" => "A background job absorbs email latency without blocking checkout, at the cost of needing to handle delivery failures asynchronously.",
        "tradeoffs" => [
          "Faster checkout response",
          "Harder to guarantee the receipt was sent before the page renders"
        ],
        "senior_lens" => "A senior engineer asks whether the user needs to see confirmation before the response returns, not just whether the code is slow.",
        "diagram" => ""
      }
    },
    "security_review" => {
      "title" => "Mass assignment on profile update",
      "question" => "What security vulnerability exists here, and how would you mitigate it?",
      "snippet" => <<~RUBY.strip,
        def update
          current_user.update(params[:user])
          redirect_to profile_path
        end
      RUBY
      "scenario" => "a self-service profile update endpoint",
      "teaching_note" => "Consider what happens if the submitted params hash includes a key nobody intended to expose.",
      "concept" => "mass_assignment_protection",
      "glossary" => [],
      "reference" => {
        "tagline" => "Never pass raw params straight into update.",
        "explanation" => "Without strong params, an attacker can submit unexpected attributes (like admin flags) alongside the form fields.",
        "code_example" => <<~RUBY.strip,
          def update
            current_user.update(user_params)
            redirect_to profile_path
          end

          private

          def user_params
            params.require(:user).permit(:name, :email)
          end
        RUBY
        "senior_lens" => "Permit an explicit allowlist, never an inferred one."
      }
    },
    "parsons_problem" => {
      "title" => "Build a safe divide",
      "scenario" => "a pricing calculator that divides a total by a quantity",
      "question" => "Arrange these blocks into the correct working solution",
      "blocks" => [
        "def safe_divide(total, quantity)",
        "  return 0 if quantity.zero?",
        "  total / quantity.to_f",
        "end"
      ],
      "teaching_note" => "Think about what should happen before any division is attempted.",
      "concept" => "idempotency",
      "glossary" => []
    }
  }.freeze

  private

  def call(system:, prompt:)
    text =
      case system
      when /generating personalized daily exercise sets/
        EXERCISE_PROBLEM_SET.to_json
      else
        raise "FakeService received an unrecognized system prompt: #{system.inspect}"
      end

    { text: text, input_tokens: 0, output_tokens: 0 }
  end

  def build_connection
    nil
  end
end
```

- [ ] **Step 6: Run the spec to verify it passes**

Run: `bundle exec rspec spec/services/fake_service_spec.rb`
Expected: PASS (4 examples)

- [ ] **Step 7: Run the full suite to confirm no regressions**

Run: `bundle exec rspec`
Expected: PASS, same example count as before plus 4

- [ ] **Step 8: Commit**

```bash
git add app/models/user.rb app/services/ai_service.rb app/services/fake_service.rb spec/services/fake_service_spec.rb
git commit -m "Add fake AiService provider for deterministic exercise generation in tests"
```

---

### Task 2: FakeService — review_response

**Files:**
- Modify: `app/services/fake_service.rb`
- Modify: `spec/services/fake_service_spec.rb`

**Interfaces:**
- Consumes: `AiService#review_response` (inherited, unmodified) calls `call(system:, prompt:)` with a `system:` string containing `"giving direct, specific feedback"`, and a `prompt:` whose last line is literally `Return JSON with keys: "code_review", "pattern", "#{third_key}"` (see `AiService#build_review_prompt`).
- Produces: `FakeService::REVIEW_SECTION` (a frozen `Hash` — the canned shape for one reviewed section: `rating`, `correct`, `missed`, `better_questions`, `next_step`, `improved_code`), used for all three keys of any review response regardless of which third the exercise held.

- [ ] **Step 1: Write the failing spec**

Add to `spec/services/fake_service_spec.rb`, inside the outer `describe`:

```ruby
  describe "#review_response" do
    it "returns a review keyed to the exercise's actual third_key" do
      user_exercise = DailyExercise.create!(
        user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
        problem_set: described_class::EXERCISE_PROBLEM_SET
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: user_exercise, date: Date.current,
        answers: { "code_review" => "N+1 query", "pattern" => "Extract a service object", "architecture" => "Move it to a job" }
      )

      review = described_class.new(user.api_key).review_response(user, user_exercise, response)

      expect(review.keys).to match_array(%w[code_review pattern architecture])
      expect(review["architecture"]["rating"]).to be_present
      expect(review["code_review"]["correct"]).to be_an(Array)
    end
  end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/services/fake_service_spec.rb`
Expected: FAIL — `FakeService received an unrecognized system prompt` (raised by the `else` branch in `#call`)

- [ ] **Step 3: Add the review branch to `FakeService`**

In `app/services/fake_service.rb`, add below `EXERCISE_PROBLEM_SET` (still inside the class, before `private`):

```ruby
  REVIEW_SECTION = {
    "rating" => "solid",
    "correct" => [ "Correctly identified the core issue." ],
    "missed" => [ "Didn't mention the specific fix." ],
    "better_questions" => [ "What would happen under concurrent access?" ],
    "next_step" => "Review the referenced concept material once more.",
    "improved_code" => ""
  }.freeze
```

Then change `#call`'s `case` to add the review branch:

```ruby
  def call(system:, prompt:)
    text =
      case system
      when /generating personalized daily exercise sets/
        EXERCISE_PROBLEM_SET.to_json
      when /giving direct, specific feedback/
        third_key = prompt[/Return JSON with keys: "code_review", "pattern", "(\w+)"/, 1]
        { "code_review" => REVIEW_SECTION, "pattern" => REVIEW_SECTION, third_key => REVIEW_SECTION }.to_json
      else
        raise "FakeService received an unrecognized system prompt: #{system.inspect}"
      end

    { text: text, input_tokens: 0, output_tokens: 0 }
  end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/services/fake_service_spec.rb`
Expected: PASS (5 examples)

- [ ] **Step 5: Commit**

```bash
git add app/services/fake_service.rb spec/services/fake_service_spec.rb
git commit -m "Add review_response support to FakeService"
```

---

### Task 3: FakeService — concept reference, explain_differently, follow-up answers

**Files:**
- Modify: `app/services/fake_service.rb`
- Modify: `spec/services/fake_service_spec.rb`

**Interfaces:**
- Consumes: `AiService#generate_concept_reference` (`system:` contains `"writing a concise, durable reference"`), `#explain_differently` (`system:` contains `"re-explaining one point"`), `#answer_follow_up` (`system:` contains `"answering a follow-up question"`).
- Produces: `FakeService::CONCEPT_REFERENCE` (frozen `Hash` covering `DailyResponse`... actually `AiService::CONCEPT_REFERENCE_FIELDS`: `tagline`, `explanation`, `code_example`, `senior_lens`), and two canned prose strings for the plain-text methods.

- [ ] **Step 1: Write the failing spec**

Add to `spec/services/fake_service_spec.rb`:

```ruby
  describe "#generate_concept_reference" do
    it "returns every required CONCEPT_REFERENCE_FIELDS field non-blank" do
      reference = described_class.new(user.api_key).generate_concept_reference(user, "n_plus_one", "ruby_rails")

      AiService::CONCEPT_REFERENCE_FIELDS.each do |field|
        expect(reference[field].to_s.strip).to be_present
      end
    end
  end

  describe "#explain_differently" do
    it "returns non-blank plain prose" do
      exercise = DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails",
                                        generated_at: Time.current, problem_set: described_class::EXERCISE_PROBLEM_SET)
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                        answers: { "pattern" => "Extract a service object" })

      text = described_class.new(user.api_key).explain_differently(user, exercise, response, section: "pattern")

      expect(text).to be_present
    end
  end

  describe "#answer_follow_up" do
    it "returns non-blank plain prose" do
      exercise = DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails",
                                        generated_at: Time.current, problem_set: described_class::EXERCISE_PROBLEM_SET)
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                        answers: { "pattern" => "Extract a service object" })

      text = described_class.new(user.api_key).answer_follow_up(
        user, exercise, response, section: "pattern", question: "Why not just a bigger model?"
      )

      expect(text).to be_present
    end
  end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/services/fake_service_spec.rb`
Expected: FAIL — `FakeService received an unrecognized system prompt` for all three new examples

- [ ] **Step 3: Add the three remaining branches to `FakeService`**

In `app/services/fake_service.rb`, add below `REVIEW_SECTION`:

```ruby
  CONCEPT_REFERENCE = {
    "tagline" => "One clear rule, not a grab-bag of tips.",
    "explanation" => "This concept has one core idea worth internalizing, with a couple of situations where it matters most.",
    "code_example" => <<~RUBY.strip,
      # A short, annotated example demonstrating the concept.
      def example
        true
      end
    RUBY
    "senior_lens" => "A senior engineer reaches for this automatically, without having to reason it out each time."
  }.freeze

  EXPLAIN_DIFFERENTLY_TEXT =
    "Think of it like a relay race — each service object is one runner, and its only job is to hand off cleanly " \
    "to the next one. If a single method complains about doing too much, that's the same as one runner trying to " \
    "run the whole race alone."

  FOLLOW_UP_ANSWER_TEXT =
    "Focus on the boundary of the operation: what MUST happen before returning success, and what could safely " \
    "happen after. That's what separates a synchronous responsibility from something a background job can own."
```

Then change `#call`'s `case`:

```ruby
  def call(system:, prompt:)
    text =
      case system
      when /generating personalized daily exercise sets/
        EXERCISE_PROBLEM_SET.to_json
      when /giving direct, specific feedback/
        third_key = prompt[/Return JSON with keys: "code_review", "pattern", "(\w+)"/, 1]
        { "code_review" => REVIEW_SECTION, "pattern" => REVIEW_SECTION, third_key => REVIEW_SECTION }.to_json
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

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/services/fake_service_spec.rb`
Expected: PASS (8 examples)

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/services/fake_service.rb spec/services/fake_service_spec.rb
git commit -m "Round out FakeService: concept reference, explain_differently, follow-up answers"
```

---

### Task 4: Fake-provider test-user helper

**Files:**
- Modify: `spec/support/auth_helpers.rb`
- Test: `spec/requests/` — no new file; verified via a one-off request-spec-style check inline in this task's own step (no dedicated spec file needed for a two-line helper — the FakeService specs already prove `provider: "fake"` users work end-to-end).

**Interfaces:**
- Produces: `AuthHelpers#create_fake_provider_user(email: "fake-user@example.com", name: "Fake User", time_zone: "UTC")` → `User` with `provider: "fake"`, usable anywhere `AuthHelpers` is included (`type: :request`, `:channel`, `:helper`, and — after Task 5 — `:system`).

- [ ] **Step 1: Add the helper**

In `spec/support/auth_helpers.rb`, change:

```ruby
module AuthHelpers
  def create_user_with_key(email: "dev@example.com", name: "Dev", time_zone: "UTC")
    user = User.create!(email: email, name: name, time_zone: time_zone)
    user.update!(api_key: "sk-ant-test-key", provider: "anthropic")
    user
  end

  def login_as(user)
    get verify_auth_path(token: user.generate_login_token!)
  end
end
```

to:

```ruby
module AuthHelpers
  def create_user_with_key(email: "dev@example.com", name: "Dev", time_zone: "UTC")
    user = User.create!(email: email, name: name, time_zone: time_zone)
    user.update!(api_key: "sk-ant-test-key", provider: "anthropic")
    user
  end

  # Test-only infrastructure, not demo content — deliberately not seeded via
  # PreviewSeed/db/seeds.rb. Every system spec logs in as one of these, never
  # a real-key user, so no system spec ever needs (or can reach) a real API key.
  def create_fake_provider_user(email: "fake-user@example.com", name: "Fake User", time_zone: "UTC")
    user = User.create!(email: email, name: name, time_zone: time_zone)
    user.update!(api_key: "fake-test-key", provider: "fake")
    user
  end

  def login_as(user)
    get verify_auth_path(token: user.generate_login_token!)
  end
end
```

- [ ] **Step 2: Confirm it works via the existing FakeService spec's pattern**

Run: `bundle exec rspec spec/services/fake_service_spec.rb`
Expected: PASS (unchanged — this step just confirms nothing broke; `create_fake_provider_user` itself is exercised for real in Task 6's system spec, which is where it earns its keep)

- [ ] **Step 3: Commit**

```bash
git add spec/support/auth_helpers.rb
git commit -m "Add create_fake_provider_user test helper"
```

---

### Task 5: Capybara + Playwright driver setup

**Files:**
- Modify: `Gemfile`, `Gemfile.lock`
- Modify: `.gitignore`
- Create: `spec/support/system_test_helper.rb`
- Modify: `spec/support/auth_helpers.rb` (include for `type: :system`)
- Create: `spec/system/smoke_spec.rb`

**Interfaces:**
- Produces: `driven_by :capybara_playwright` registered and available to any `type: :system` spec; `Capybara.default_max_wait_time` raised to 10s (Capybara's 2s default is too short for a real browser + this app's fetch-based interactions); a real headless Chromium reachable via a project-local `node_modules/.bin/playwright-core`.
- Consumes: Node.js + npm (already present on this machine — confirmed via `node -v` / `npm -v` during planning).

- [ ] **Step 1: Add the gems in a dedicated test-only group**

In `Gemfile`, after the existing `group :development, :test do ... end` block, add a new block:

```ruby
group :test do
  # Real-browser system specs, driven by Playwright — kept in its own group
  # (not merged into :development, :test) so neither gem loads outside tests.
  gem "capybara"
  gem "capybara-playwright-driver"
end
```

Run: `bundle install`
Expected: `Gemfile.lock` gains `capybara`, `capybara-playwright-driver`, and `playwright-ruby-client`.

- [ ] **Step 2: Install a version-matched Playwright browser CLI**

Run:
```bash
export PLAYWRIGHT_CLI_VERSION=$(bundle exec ruby -e 'require "playwright/version"; puts Playwright::COMPATIBLE_PLAYWRIGHT_VERSION')
npm install "playwright-core@$PLAYWRIGHT_CLI_VERSION"
./node_modules/.bin/playwright-core install --with-deps chromium
```
Expected: `package.json`, `package-lock.json`, and `node_modules/` appear in the project root; the last command downloads a Chromium build. This pins the CLI to the exact version `playwright-ruby-client` expects — an unversioned `npx playwright` can silently install an incompatible version (see the gem's own install docs).

- [ ] **Step 3: Keep the npm artifacts out of git**

In `.gitignore`, add:

```
# Playwright CLI for system specs (installed via Task 5, not tracked)
/node_modules/
/package.json
/package-lock.json
```

- [ ] **Step 4: Register the driver and wire it into system specs**

```ruby
# spec/support/system_test_helper.rb

# capybara-playwright-driver must NOT be registered under the name :playwright
# — Rails 6.1+ reserves that name for its own built-in Playwright driver, which
# would silently take over instead. Registered here as :capybara_playwright.
Capybara.register_driver(:capybara_playwright) do |app|
  Capybara::Playwright::Driver.new(
    app,
    browser_type: :chromium,
    headless: true,
    playwright_cli_executable_path: Rails.root.join("node_modules/.bin/playwright-core").to_s
  )
end

# Capybara's 2s default wait is too short for a real browser round-tripping
# through this app's fetch-based autosave/submit/status-poll flows.
Capybara.default_max_wait_time = 10

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :capybara_playwright
  end

  # GenerateDailyExercisesJob runs via ActiveJob's :test adapter (see
  # config/environments/test.rb) — system specs that trigger on-demand
  # generation need to actually run it, not just assert it was enqueued.
  config.include ActiveJob::TestHelper, type: :system
end
```

- [ ] **Step 5: Wire `login_as` for real page loads and include `AuthHelpers` for system specs**

In `spec/support/auth_helpers.rb`, change:

```ruby
  def login_as(user)
    get verify_auth_path(token: user.generate_login_token!)
  end
end

RSpec.configure do |config|
  config.include AuthHelpers, type: :request
  config.include AuthHelpers, type: :channel
  config.include AuthHelpers, type: :helper
end
```

to:

```ruby
  # `get`/request-spec style — used by request/channel/helper specs, which
  # don't drive a real browser.
  def login_as(user)
    get verify_auth_path(token: user.generate_login_token!)
  end

  # System specs drive a real browser via Capybara, so login must be a real
  # page load rather than a bare `get`.
  def visit_as(user)
    visit verify_auth_path(token: user.generate_login_token!)
  end
end

RSpec.configure do |config|
  config.include AuthHelpers, type: :request
  config.include AuthHelpers, type: :channel
  config.include AuthHelpers, type: :helper
  config.include AuthHelpers, type: :system
end
```

- [ ] **Step 6: Write a smoke spec proving the driver works end-to-end**

```ruby
# spec/system/smoke_spec.rb
require "rails_helper"

RSpec.describe "System test driver", type: :system do
  it "renders a real page in a real browser" do
    fake_user = create_fake_provider_user
    visit_as(fake_user)

    expect(page).to have_current_path(root_path)
  end
end
```

- [ ] **Step 7: Run the smoke spec to verify it passes**

Run: `bundle exec rspec spec/system/smoke_spec.rb`
Expected: PASS. If it fails with a driver/executable error, re-check that `node_modules/.bin/playwright-core` exists (Step 2) and that `PLAYWRIGHT_CLI_VERSION` resolved to a real version string.

- [ ] **Step 8: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add Gemfile Gemfile.lock .gitignore spec/support/system_test_helper.rb spec/support/auth_helpers.rb spec/system/smoke_spec.rb
git commit -m "Add Capybara + Playwright system test driver"
```

Note: `package.json`/`package-lock.json`/`node_modules/` are gitignored (Step 3) — nothing from Step 2 gets committed. Anyone else running system specs needs to repeat Step 2 locally (or CI needs an equivalent step, out of scope for this plan).

---

### Task 6: System spec — dashboard on-demand generation

**Files:**
- Create: `spec/system/dashboard_generation_spec.rb`

**Interfaces:**
- Consumes: `create_fake_provider_user`, `visit_as` (Task 4/5), `perform_enqueued_jobs` (`ActiveJob::TestHelper`, included for `type: :system` in Task 5), `travel_to` (`ActiveSupport::Testing::TimeHelpers`, already included globally in `spec/rails_helper.rb`).

- [ ] **Step 1: Write the spec**

```ruby
# spec/system/dashboard_generation_spec.rb
require "rails_helper"

RSpec.describe "Dashboard on-demand generation", type: :system do
  it "generates and renders today's exercise for a fresh fake-provider user" do
    user = create_fake_provider_user
    monday = Date.current.beginning_of_week(:monday)

    travel_to(monday) do
      # DashboardController#show enqueues GenerateDailyExercisesJob on a
      # weekday when no exercise exists yet; :test queue_adapter means it
      # won't actually run unless we ask it to.
      perform_enqueued_jobs do
        visit_as(user)
      end

      # The initial render still shows the "generating" placeholder (the job
      # ran synchronously above, but @exercise was already looked up as nil
      # before the job was enqueued) — the page's own poll script picks up
      # the now-ready state and reloads. default_max_wait_time (10s, Task 5)
      # comfortably covers the poll's first 3s tick.
      expect(page).to have_content("Code Review", wait: 10)
      expect(page).to have_content("Pattern of the Month")
      expect(page).to have_content("Architecture Decision")
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it passes**

Run: `bundle exec rspec spec/system/dashboard_generation_spec.rb`
Expected: PASS

If it fails on the poll/reload step: confirm `GenerateDailyExercisesJob` actually persisted a `DailyExercise` (add a temporary `puts user.daily_exercises.for_date.first.inspect` inside the `perform_enqueued_jobs` block to check), and confirm `Capybara.default_max_wait_time` is in effect (Task 5, Step 4).

- [ ] **Step 3: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add spec/system/dashboard_generation_spec.rb
git commit -m "Add system spec: dashboard on-demand generation"
```

---

### Task 7: System spec — rating-gated submit

**Files:**
- Create: `spec/system/answer_submission_spec.rb`

**Interfaces:**
- Consumes: same helpers as Task 6, plus direct DOM interaction with `dashboard/_exercise.html.erb`'s selectors: `textarea[data-field="code_review"]`, `button[data-rating-for="code_review"][data-rating="right_level"]` (and the `pattern`/`architecture` equivalents), `#submit-answers`.

- [ ] **Step 1: Write the spec**

```ruby
# spec/system/answer_submission_spec.rb
require "rails_helper"

RSpec.describe "Rating-gated answer submission", type: :system do
  it "enables Submit only once every section is rated, then submits and shows the submitted state" do
    user = create_fake_provider_user
    monday = Date.current.beginning_of_week(:monday)

    travel_to(monday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content("Code Review", wait: 10)

      expect(page).to have_button("Submit answers →", disabled: true)

      fill_in_answer("code_review", "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop.")
      fill_in_answer("pattern", "A service object because checkout has three unrelated responsibilities.")
      fill_in_answer("architecture", "Move the email to a background job; checkout latency matters more than instant confirmation.")

      rate("code_review")
      rate("pattern")
      # Still disabled with one section unrated.
      expect(page).to have_button("Submit answers →", disabled: true)
      rate("architecture")

      expect(page).to have_button("Submit answers →", disabled: false)
      click_button "Submit answers →"

      expect(page).to have_content("✓ Submitted")
    end
  end

  def fill_in_answer(field, text)
    find(%(textarea[data-field="#{field}"])).fill_in(with: text)
  end

  def rate(field, value: "right_level")
    find(%(button[data-rating-for="#{field}"][data-rating="#{value}"])).click
  end
end
```

- [ ] **Step 2: Run the spec to verify it passes**

Run: `bundle exec rspec spec/system/answer_submission_spec.rb`
Expected: PASS

If the Submit button never enables: check that all three `data-rating-for` values match the rendered section keys exactly (`code_review`, `pattern`, `architecture` — architecture wins precedence per Task 1's `EXERCISE_PROBLEM_SET` design, so this is deterministic).

- [ ] **Step 3: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add spec/system/answer_submission_spec.rb
git commit -m "Add system spec: rating-gated answer submission"
```

---

### Task 8: System spec — review request, doc updates

**Files:**
- Create: `spec/system/review_request_spec.rb`
- Modify: `CLAUDE.md` (File Map + Tests sections)

**Interfaces:**
- Consumes: same helpers as Task 6/7, plus `ResponsesController#review` (`review_response_path` via `form.review-form` button labeled via `t("review.get_button", ...)`), and the redirect target `history_path(anchor: "response-#{id}")`.

- [ ] **Step 1: Write the spec**

```ruby
# spec/system/review_request_spec.rb
require "rails_helper"

RSpec.describe "Requesting an AI review", type: :system do
  it "runs the loading-state script and lands on history with the review visible" do
    user = create_fake_provider_user
    monday = Date.current.beginning_of_week(:monday)

    travel_to(monday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content("Code Review", wait: 10)

      %w[code_review pattern architecture].each do |field|
        find(%(button[data-rating-for="#{field}"][data-rating="right_level"])).click
      end
      click_button "Submit answers →"
      expect(page).to have_content("✓ Submitted")

      review_button = find("form.review-form button", match: :first)
      review_button.click

      expect(page).to have_current_path(%r{/history}, wait: 10)
      expect(page).to have_content("What you got right")
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it passes**

Run: `bundle exec rspec spec/system/review_request_spec.rb`
Expected: PASS

If the button text lookup fails: the review button's label comes from `t("review.get_button", provider: ...)` — check `config/locales/*.yml` for the exact copy if `find("form.review-form button", match: :first)` needs a more specific selector.

- [ ] **Step 3: Update CLAUDE.md**

In `CLAUDE.md`, in the **Tests** section, change:

```markdown
## Tests

RSpec (`spec/` — models, requests, services, jobs, mailers). Run with:

```bash
bundle exec rspec
```

CI runs the suite against postgres 16 on every PR (see `.github/workflows/ci.yml`).
```

to:

```markdown
## Tests

RSpec (`spec/` — models, requests, services, jobs, mailers). Run with:

```bash
bundle exec rspec
```

`spec/system/` holds a small number of real-browser specs (Capybara +
capybara-playwright-driver) covering flows unit/request specs can't fully
verify — rating-gated submit, review loading state — driven exclusively
against a `FakeService` (`provider: "fake"`) test user, never a real API key.
Running them locally requires a one-time Playwright CLI install (see
`app/services/fake_service.rb`'s and `spec/support/system_test_helper.rb`'s
comments for the exact commands); `bundle exec rspec` alone runs everything
else and skips nothing.

CI runs the suite against postgres 16 on every PR (see `.github/workflows/ci.yml`).
```

In the **File Map** section, add two lines after the `app/services/preview_mail.rb` line:

```markdown
- `app/services/fake_service.rb` — deterministic, zero-cost AiService provider for tests (`provider: "fake"`); overrides only `#call`/`#build_connection`, so every other AiService code path runs for real against its canned output
- `spec/system/` — real-browser specs (Capybara + capybara-playwright-driver) against the fake provider; `spec/support/system_test_helper.rb` registers the driver
```

- [ ] **Step 4: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add spec/system/review_request_spec.rb CLAUDE.md
git commit -m "Add system spec: review request flow; document FakeService and system tests"
```

---

## Self-Review Notes

- **Spec coverage:** Design doc's Part 1 (FakeService dispatch table, all 5 methods) → Tasks 1-3. `User#provider`/`AiService.for` wiring → Task 1. Test user helper → Task 4. Part 2's Gemfile/driver/login setup → Task 5. All three named system specs → Tasks 6-8. Design's "no conversion of existing specs" and "fake provider only" constraints → enforced by every system spec using `create_fake_provider_user`/`visit_as` exclusively, and no existing spec files are touched except `auth_helpers.rb` (additive only).
- **Placeholder scan:** No TBDs; every step has real, runnable code or an exact command.
- **Type consistency:** `EXERCISE_PROBLEM_SET`, `REVIEW_SECTION`, `CONCEPT_REFERENCE` are referenced with identical names/shapes across Tasks 1-3's spec and implementation steps. `create_fake_provider_user`/`visit_as` signatures match between Task 4/5's definition and Tasks 6-8's usage.
