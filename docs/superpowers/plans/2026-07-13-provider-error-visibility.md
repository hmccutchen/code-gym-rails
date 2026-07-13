# Provider Error Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `AiService::Error` messages carry the provider's own explanation of a failed API call (e.g. "Your credit balance is too low to access the Anthropic API") instead of a bare HTTP status code, so users can act on it themselves.

**Architecture:** Add one shared private helper (`AiService#extract_provider_message`) that parses a failed response body as JSON and pulls `error.message` — the shape both Anthropic and Gemini use. `ClaudeService#call` and `GeminiService#call` each use it in place of their current hardcoded `"<Provider> API error <status>"` string, falling back to that same string whenever the body isn't parseable JSON or lacks the field. No other file changes — the three existing user-facing surfaces (`daily_exercises_controller#regenerate`, `responses_controller#review`, `generate_daily_exercises_job`) already display `e.message` verbatim in ERB templates that auto-escape it.

**Tech Stack:** Ruby on Rails 8, RSpec, Faraday (already in use — no new dependencies).

## Global Constraints

- No new UI surfaces, banners, or pages — reuse the three existing failure surfaces unchanged.
- Pass through the provider's message **verbatim** — no categorization into friendly buckets (credit exhausted / invalid key / rate limited / other).
- No length cap/truncation on the extracted message.
- Fallback to today's exact `"Claude API error #{status}"` / `"Gemini API error #{status}"` strings whenever the body isn't parseable JSON or lacks `error.message` — this preserves all four existing tests per service spec unchanged.
- The existing `log_raw_snippet` call (full raw body logged server-side) stays exactly as-is in both services, regardless of whether parsing succeeds.
- No changes to magic-link auth, Resend/SMTP, `/test_login`, or any of the visual-feedback work (ActionCable broadcasts, weekday guard, regenerate spinner) from the other in-review branch.

---

### Task 1: Shared error-message helper in `AiService`, wired into `ClaudeService`

**Files:**
- Modify: `app/services/ai_service.rb` (add private helper, near `parse_json_response`)
- Modify: `app/services/claude_service.rb:20-23` (use the helper)
- Test: `spec/services/ai_service_spec.rb` (add `describe "#extract_provider_message"` block)
- Test: `spec/services/claude_service_spec.rb` (add one new `it` inside the existing `describe "#call"` block)

**Interfaces:**
- Produces: `AiService#extract_provider_message(body, fallback:)` (private instance method, returns a `String`) — Task 2's `GeminiService` change also calls this exact method with the exact same signature.

- [ ] **Step 1: Write the failing helper spec**

Open `spec/services/ai_service_spec.rb`. Add this new `describe` block anywhere after the existing `describe "#parse_json_response"` block (e.g. right before `describe "#generate_exercise"`):

```ruby
  describe "#extract_provider_message" do
    it "returns the provider's error.message when the body is a matching JSON error object" do
      body = {
        "type"  => "error",
        "error" => { "type" => "insufficient_quota", "message" => "Your credit balance is too low to access the Anthropic API." }
      }.to_json

      expect(service.send(:extract_provider_message, body, fallback: "fallback text"))
        .to eq("Your credit balance is too low to access the Anthropic API.")
    end

    it "falls back when the body is not JSON" do
      expect(service.send(:extract_provider_message, "not json", fallback: "fallback text"))
        .to eq("fallback text")
    end

    it "falls back when the JSON body has no error.message" do
      body = { "type" => "error", "error" => { "type" => "overloaded_error" } }.to_json

      expect(service.send(:extract_provider_message, body, fallback: "fallback text"))
        .to eq("fallback text")
    end

    it "falls back when error.message is blank" do
      body = { "error" => { "message" => "" } }.to_json

      expect(service.send(:extract_provider_message, body, fallback: "fallback text"))
        .to eq("fallback text")
    end
  end
```

This uses the file's existing `service` let (a minimal concrete `AiService` subclass defined at the top of the file) — no new setup needed.

- [ ] **Step 2: Run the new spec to verify it fails**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "#extract_provider_message"`
Expected: FAIL with `NoMethodError` or `undefined method 'extract_provider_message'` (the method doesn't exist yet).

- [ ] **Step 3: Implement the helper in `AiService`**

In `app/services/ai_service.rb`, add this private method directly after `parse_json_response` (which ends around line 243, right before the `log_raw_snippet` method):

```ruby
  # Extracts a provider's own explanation for a failed HTTP response, when
  # one is available, so users see actionable detail (e.g. "credit balance
  # too low") instead of a bare status code. Falls back to `fallback`
  # whenever the body isn't parseable JSON or lacks the expected shape (5xx
  # HTML error pages, empty bodies, unrecognized formats). Both Anthropic
  # and Gemini nest their error detail the same way:
  # {"error": {"type": "...", "message": "..."}}.
  def extract_provider_message(body, fallback:)
    parsed  = JSON.parse(body)
    message = parsed.dig("error", "message")
    message.presence || fallback
  rescue JSON::ParserError
    fallback
  end
```

- [ ] **Step 4: Run the helper spec to verify it passes**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "#extract_provider_message"`
Expected: PASS, 4 examples, 0 failures.

- [ ] **Step 5: Write the failing `ClaudeService` spec**

Open `spec/services/claude_service_spec.rb`. Add this new `it` inside the existing `describe "#call"` block, right after the `"raises AiService::Error on a non-success response"` test:

```ruby
    it "surfaces the provider's own error message when the body includes one" do
      body = {
        "type"  => "error",
        "error" => { "type" => "insufficient_quota", "message" => "Your credit balance is too low to access the Anthropic API." }
      }.to_json
      fake_response = instance_double(Faraday::Response, success?: false, status: 400, body: body)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error, "Your credit balance is too low to access the Anthropic API.")
    end
```

- [ ] **Step 6: Run it to verify it fails**

Run: `bundle exec rspec spec/services/claude_service_spec.rb -e "surfaces the provider's own error message"`
Expected: FAIL — the raised message is still `"Claude API error 400"`, not the provider's text.

- [ ] **Step 7: Wire the helper into `ClaudeService#call`**

In `app/services/claude_service.rb`, replace:

```ruby
    unless resp.success?
      log_raw_snippet("Claude API error #{resp.status} body", resp.body)
      raise AiService::Error, "Claude API error #{resp.status}"
    end
```

with:

```ruby
    unless resp.success?
      log_raw_snippet("Claude API error #{resp.status} body", resp.body)
      raise AiService::Error, extract_provider_message(resp.body, fallback: "Claude API error #{resp.status}")
    end
```

- [ ] **Step 8: Run the full `ClaudeService` spec file to verify everything passes**

Run: `bundle exec rspec spec/services/claude_service_spec.rb`
Expected: PASS, all examples green (the 3 pre-existing `#call` failure-path tests plus the new one). The pre-existing "raises AiService::Error on a non-success response" test uses a plain-string body (`"boom"`), which isn't parseable JSON, so it still falls back to `"Claude API error 500"` — unchanged. The "does not leak the raw response body" and "logs a truncated snippet" tests use non-JSON huge bodies too, so they also still fall back correctly.

- [ ] **Step 9: Run the full `AiService` spec file to verify no regressions**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS, all examples green.

- [ ] **Step 10: Commit**

```bash
git add app/services/ai_service.rb app/services/claude_service.rb spec/services/ai_service_spec.rb spec/services/claude_service_spec.rb
git commit -m "Surface provider error messages instead of bare status codes (Claude)

Adds AiService#extract_provider_message, a shared helper that parses a
failed response body as JSON and returns error.message when present,
falling back to the existing '<Provider> API error <status>' string
otherwise. Wired into ClaudeService#call.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 2: Wire the same helper into `GeminiService`

**Files:**
- Modify: `app/services/gemini_service.rb:20-23`
- Test: `spec/services/gemini_service_spec.rb` (add one new `it` inside the existing `describe "#call"` block)

**Interfaces:**
- Consumes: `AiService#extract_provider_message(body, fallback:)` from Task 1 — same private method, called identically to `ClaudeService`.

- [ ] **Step 1: Write the failing `GeminiService` spec**

Open `spec/services/gemini_service_spec.rb`. Add this new `it` inside the existing `describe "#call"` block, right after the `"raises AiService::Error on a non-success response"` test:

```ruby
    it "surfaces the provider's own error message when the body includes one" do
      body = {
        "error" => {
          "code"    => 429,
          "message" => "Resource has been exhausted (e.g. check quota).",
          "status"  => "RESOURCE_EXHAUSTED"
        }
      }.to_json
      fake_response = instance_double(Faraday::Response, success?: false, status: 429, body: body)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error, "Resource has been exhausted (e.g. check quota).")
    end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/services/gemini_service_spec.rb -e "surfaces the provider's own error message"`
Expected: FAIL — the raised message is still `"Gemini API error 429"`, not the provider's text.

- [ ] **Step 3: Wire the helper into `GeminiService#call`**

In `app/services/gemini_service.rb`, replace:

```ruby
    unless resp.success?
      log_raw_snippet("Gemini API error #{resp.status} body", resp.body)
      raise AiService::Error, "Gemini API error #{resp.status}"
    end
```

with:

```ruby
    unless resp.success?
      log_raw_snippet("Gemini API error #{resp.status} body", resp.body)
      raise AiService::Error, extract_provider_message(resp.body, fallback: "Gemini API error #{resp.status}")
    end
```

- [ ] **Step 4: Run the full `GeminiService` spec file to verify everything passes**

Run: `bundle exec rspec spec/services/gemini_service_spec.rb`
Expected: PASS, all examples green. The pre-existing failure-path tests use non-JSON bodies (`"overloaded"`, huge plain-text strings), so they still fall back to `"Gemini API error 503"` unchanged.

- [ ] **Step 5: Run the full test suite to verify no regressions anywhere**

Run: `bundle exec rspec`
Expected: PASS, all examples green (no failures anywhere in the suite — this change only touches error-message construction inside two service classes).

- [ ] **Step 6: Commit**

```bash
git add app/services/gemini_service.rb spec/services/gemini_service_spec.rb
git commit -m "Surface provider error messages instead of bare status codes (Gemini)

Wires GeminiService#call into the shared AiService#extract_provider_message
helper added in the previous commit, mirroring the ClaudeService change.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Self-Review Notes

- **Spec coverage:** Every requirement in `docs/superpowers/specs/2026-07-13-provider-error-visibility-design.md` maps to a task step — shared helper (Task 1, Steps 1-4), Claude wiring (Task 1, Steps 5-8), Gemini wiring (Task 2), verbatim pass-through with no categorization (helper does no bucketing), no length cap (helper has none), fallback behavior preserved (existing non-JSON tests re-verified in Steps 8-9 and Task 2 Step 4-5), no changes to downstream surfaces (none of the three surfaces appear in any task's file list).
- **Placeholder scan:** No TBD/TODO; every step shows complete, exact code.
- **Type consistency:** `extract_provider_message(body, fallback:)` signature is identical everywhere it's referenced (defined once in Task 1, consumed identically in Task 1's `ClaudeService` call site and Task 2's `GeminiService` call site).
