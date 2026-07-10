# Feedback UI, Teaching Notes, Concept Tagging — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the existing rating/feedback endpoint in the right place in the dashboard flow, add an on-demand teaching hint per generated problem, and tag every problem with a fixed-vocabulary concept that feeds back into daily generation.

**Architecture:** Three independently shippable tasks in strict order. Task 1 is view-only (re-gate the existing feedback widget + fix the AI-review renderer + fix invalid nested-form HTML). Task 2 adds `teaching_note` to the generation schema/prompt and a gated reveal in the dashboard. Task 3 adds a `concept` per problem (fixed vocabulary on `ClaudeService`), the project's one migration (`concept_tags` jsonb on `daily_responses`), copy-on-save in `ResponsesController#create`, and the mastery-tracking loop in the generation prompt.

**Tech Stack:** Rails 8.0.5, RSpec request/model/service specs, jsonb columns, ERB views with the existing inline-`<script>` pattern (no JS framework).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-10-feedback-teaching-tagging-design.md` — follow it exactly.
- Magic-link auth flow, Resend delivery config, and the `/test_login` route are untouched.
- Old rows never break: `problem_set` without `teaching_note`/`concept` and `daily_responses` without tags render and personalize exactly as today (`.presence`/nil guards at every read site). No backfill, no regeneration.
- The concept vocabulary is exactly this frozen list (16 entries), defined once as `ClaudeService::CONCEPTS`:
  `n_plus_one transaction_safety memoization service_objects scope_chaining idempotency authorization background_jobs caching validations callbacks_vs_service query_objects policy_objects indexing concurrency error_handling`
- Off-list concepts normalize to `"other"` at parse time.
- The only migration in this plan is `add_column :daily_responses, :concept_tags, :jsonb, default: {}`.
- Hint reveal threshold is the existing >10-character heuristic (same as the progress bar).
- No JS test framework is introduced; view behavior is asserted at the request-spec level via markup presence/absence.
- Run `bundle exec rspec` and `bundle exec rubocop` before every commit; both must be clean.

---

### Task 1: Feedback widget re-gate + AI-review renderer fix

**Files:**
- Create: `spec/support/auth_helpers.rb`
- Modify: `spec/rails_helper.rb` (uncomment the support-dir glob)
- Create: `spec/requests/dashboard_spec.rb`
- Create: `app/views/responses/_feedback_form.html.erb`
- Modify: `app/views/dashboard/show.html.erb`

**Interfaces:**
- Consumes: `ResponsesController#feedback` (`PATCH /responses/:id/feedback`, params `response[rating]`, `response[feedback_text]`) — unchanged. `DailyResponse#reviewed?`/`#submitted?` — unchanged.
- Produces: request-spec auth helpers `create_user_with_key(email:, name:)` → `User` and `login_as(user)` (Tasks 2–3 reuse them); CSS marker classes `feedback-quiet` / `feedback-prominent` that specs assert on; partial `responses/_feedback_form` with locals `response:` and `style:` (`:quiet` or `:prominent`).

- [ ] **Step 1: Enable the spec support directory and add auth helpers**

In `spec/rails_helper.rb`, replace the commented line:

```ruby
# Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }
```

with:

```ruby
Rails.root.glob("spec/support/**/*.rb").sort_by(&:to_s).each { |f| require f }
```

Create `spec/support/auth_helpers.rb`:

```ruby
module AuthHelpers
  def create_user_with_key(email: "dev@example.com", name: "Dev")
    user = User.create!(email: email, name: name)
    user.update!(api_key: "sk-ant-test-key")
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

- [ ] **Step 2: Write the failing request specs**

Create `spec/requests/dashboard_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Dashboard feedback and review display", type: :request do
  let(:user) { create_user_with_key }

  def base_problem_set
    {
      "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" },
      "pattern" => {
        "title" => "Service Objects", "why" => "Because", "question" => "When?",
        "reference" => { "tagline" => "T", "explanation" => "E",
                         "code_example" => "code", "senior_lens" => "S" }
      },
      "challenge" => { "title" => "Build", "question" => "Implement X", "starter_code" => "" }
    }
  end

  def create_exercise(problem_set: base_problem_set)
    DailyExercise.create!(user: user, date: Date.current,
                          problem_set: problem_set, generated_at: Time.current)
  end

  def create_response(exercise, submitted: true, ai_review: nil)
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "a" * 20, "pattern" => "b" * 20, "challenge" => "c" * 20 },
      submitted_at: submitted ? Time.current : nil,
      ai_review: ai_review
    )
  end

  def sample_review
    {
      "code_review" => {
        "rating" => "solid", "correct" => "Good catch on the missing index",
        "missed" => "Missed the race condition", "better_questions" => "What about locks?",
        "next_step" => "Read about advisory locks", "improved_code" => "improved_code_marker"
      },
      "pattern" => { "rating" => "developing", "correct" => "Right idea", "missed" => "",
                     "better_questions" => "", "next_step" => "", "improved_code" => "" },
      "challenge" => { "rating" => "strong", "correct" => "Clean", "missed" => "",
                       "better_questions" => "", "next_step" => "", "improved_code" => "" }
    }
  end

  before { login_as(user) }

  it "shows no feedback widget before submission" do
    create_exercise
    get root_path
    expect(response.body).not_to include("feedback-quiet")
    expect(response.body).not_to include("feedback-prominent")
  end

  it "shows the quiet feedback widget after submission, before review" do
    create_response(create_exercise)
    get root_path
    expect(response.body).to include("feedback-quiet")
    expect(response.body).not_to include("feedback-prominent")
  end

  it "shows the prominent feedback card after the review, not the quiet one" do
    create_response(create_exercise, ai_review: sample_review)
    get root_path
    expect(response.body).to include("feedback-prominent")
    expect(response.body).not_to include("feedback-quiet")
  end

  it "renders the review with the keys review_response actually returns" do
    create_response(create_exercise, ai_review: sample_review)
    get root_path
    expect(response.body).to include("Good catch on the missing index")
    expect(response.body).to include("Missed the race condition")
    expect(response.body).to include("What about locks?")
    expect(response.body).to include("Read about advisory locks")
    expect(response.body).to include("improved_code_marker")
    expect(response.body).to include("solid")
  end

  it "round-trips rating and feedback text through the feedback action" do
    resp = create_response(create_exercise)
    patch feedback_response_path(resp),
          params: { response: { rating: "too_hard", feedback_text: "less SQL please" } }
    expect(resp.reload.rating).to eq("too_hard")
    expect(resp.feedback_text).to eq("less SQL please")
  end
end
```

- [ ] **Step 3: Run the specs to verify they fail**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: the two widget-state specs and the review-keys spec FAIL (no `feedback-quiet`/`feedback-prominent` markup exists; review renders empty `summary` blocks). The no-widget-before-submission spec and the round-trip spec may already pass — that's fine.

- [ ] **Step 4: Create the feedback form partial**

Create `app/views/responses/_feedback_form.html.erb`:

```erb
<div class="<%= style == :prominent ? "feedback-prominent section" : "feedback-quiet" %>">
  <p class="feedback-title">How was today's difficulty?</p>
  <%= form_with url: feedback_response_path(response), method: :patch, data: { turbo: false } do |ff| %>
    <div class="rating-row">
      <%= ff.button "Too easy",   name: "response[rating]", value: "too_easy",    class: "rating-btn #{response.rating == 'too_easy' ? 'active' : ''}" %>
      <%= ff.button "Just right", name: "response[rating]", value: "right_level", class: "rating-btn #{response.rating == 'right_level' ? 'active' : ''}" %>
      <%= ff.button "Too hard",   name: "response[rating]", value: "too_hard",    class: "rating-btn #{response.rating == 'too_hard' ? 'active' : ''}" %>
    </div>
    <textarea name="response[feedback_text]" class="answer" style="min-height:70px;margin-top:.75rem" placeholder="Optional: anything specific to adjust next time?"><%= response.feedback_text %></textarea>
    <%= ff.submit "Save feedback", class: "btn btn-ghost btn-sm", style: "margin-top:.5rem" %>
  <% end %>
</div>
```

- [ ] **Step 5: Restructure the submitted-state UI in the dashboard view**

In `app/views/dashboard/show.html.erb`:

**5a.** Add to the `<style>` block (after the `.rating-btn.active` rule):

```css
  .feedback-quiet { margin-top: 1.5rem; opacity: .75; }
  .feedback-quiet .feedback-title { font-size: .85rem; color: var(--muted); margin-bottom: .5rem; }
  .feedback-prominent { margin-top: 1.5rem; border-color: var(--accent); }
  .feedback-prominent .feedback-title { font-size: 1rem; font-weight: 600; margin-bottom: .75rem; }
  .review-rating { display: inline-block; background: rgba(124,106,247,.15); border-radius: 4px; padding: .1rem .5rem; font-size: .75rem; margin-left: .5rem; text-transform: none; letter-spacing: 0; }
  .review-item { font-size: .9rem; line-height: 1.7; margin-top: .4rem; }
```

**5b.** The current submitted-state block (badge row, feedback widget, review display — everything from `<% if submitted %>` at line ~130 through its `<% end %>` before the unsubmitted `submit-row`) renders **inside** the main `gym-form` `form_with`. Nested `<form>` tags are invalid HTML (browsers drop the inner tag, so the feedback POST can go through the wrong form). Restructure so the main form closes right after the three sections, and the submitted-state UI renders after it. Replace the whole region from `<%# ── Submit / Review ── %>` through the end of the `form_with` block with:

```erb
    <%# ── Submit (unsubmitted state only) ─────────────────────────────── %>
    <% unless submitted %>
      <div class="submit-row">
        <%= f.hidden_field :submit, value: "1" %>
        <%= f.submit "Submit answers →", class: "btn btn-primary" %>
        <span style="font-size:.8rem;color:var(--muted)">Auto-saved as you type</span>
      </div>
    <% end %>
  <% end %>

  <%# ── Post-submission: badge, review, feedback (outside the main form —
       nested forms are invalid HTML and break the inner submits) ───────── %>
  <% if submitted %>
    <div class="submit-row">
      <span class="submitted-badge">✓ Submitted</span>
      <% unless @response.reviewed? %>
        <%= button_to "Get Claude review →", review_response_path(@response), method: :post, class: "btn btn-primary btn-sm" %>
      <% end %>
    </div>

    <% if @response.reviewed? %>
      <div class="review-section">
        <h3 style="font-size:1rem;margin-bottom:.75rem">Claude's Review</h3>
        <% @response.ai_review.each do |section, fb| %>
          <% next unless fb.is_a?(Hash) %>
          <div class="review-block">
            <h4><%= section.humanize %><% if fb["rating"].present? %><span class="review-rating"><%= fb["rating"] %></span><% end %></h4>
            <% { "correct" => "What you got right",
                 "missed" => "What you missed",
                 "better_questions" => "Questions to ask yourself",
                 "next_step" => "Next step" }.each do |key, label| %>
              <% if fb[key].present? %>
                <p class="review-item"><strong><%= label %>:</strong> <%= fb[key] %></p>
              <% end %>
            <% end %>
            <% if fb["improved_code"].present? %>
              <pre class="snippet" style="margin-top:.75rem"><code><%= fb["improved_code"] %></code></pre>
            <% end %>
          </div>
        <% end %>
      </div>
      <%= render "responses/feedback_form", response: @response, style: :prominent %>
    <% else %>
      <%= render "responses/feedback_form", response: @response, style: :quiet %>
    <% end %>
  <% end %>
```

(The old inline feedback widget and the old `summary`-based review renderer are deleted by this replacement. The `<% if @response.persisted? %><input type="hidden" name="_method" value="patch"><% end %>` inside the main form stays as-is.)

- [ ] **Step 6: Run the specs to verify they pass**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: 5 examples, 0 failures.

- [ ] **Step 7: Full suite + lint**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: all examples pass (32 = 27 existing + 5 new), no offenses.

- [ ] **Step 8: Commit**

```bash
git add spec/support/auth_helpers.rb spec/rails_helper.rb spec/requests/dashboard_spec.rb app/views/responses/_feedback_form.html.erb app/views/dashboard/show.html.erb
git commit -m "Re-gate feedback widget around AI review; fix review renderer keys

Feedback is quiet after submission, prominent after the review. The
review renderer now uses the keys review_response actually returns
(rating/correct/missed/better_questions/next_step/improved_code) instead
of the nonexistent 'summary'. Post-submission UI moves outside the main
form, fixing pre-existing invalid nested-form HTML."
```

---

### Task 2: Teaching notes (schema, prompt, gated reveal)

**Files:**
- Create: `spec/services/claude_service_spec.rb`
- Modify: `spec/requests/dashboard_spec.rb` (add hint specs)
- Modify: `app/services/claude_service.rb` (EXERCISE_SCHEMA + prompt instruction)
- Create: `app/views/dashboard/_teaching_hint.html.erb`
- Modify: `app/views/dashboard/show.html.erb` (render hint per section + CSS + JS unlock)

**Interfaces:**
- Consumes: `create_user_with_key` / `login_as` from `spec/support/auth_helpers.rb` (Task 1); `base_problem_set`/`create_exercise` helpers inside `spec/requests/dashboard_spec.rb` (Task 1).
- Produces: `problem_set` sections may carry `"teaching_note"` (string); partial `dashboard/_teaching_hint` with locals `note:, field:, submitted:, answer:`; CSS classes `hint` / `locked` and `data-hint-for` attribute that the inline script and Task 3 leave untouched.

- [ ] **Step 1: Write the failing service specs**

Create `spec/services/claude_service_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ClaudeService do
  let(:service) { ClaudeService.new("sk-ant-test") }
  let(:user) { User.create!(email: "prompt@example.com", name: "Prompt") }

  describe "EXERCISE_SCHEMA" do
    it "defines a teaching_note for each of the three sections" do
      expect(ClaudeService::EXERCISE_SCHEMA.scan('"teaching_note"').size).to eq(3)
    end
  end

  describe "#build_exercise_prompt" do
    it "instructs that teaching notes hint without giving the answer" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("teaching_note")
      expect(prompt.downcase).to include("never the full answer")
    end
  end
end
```

- [ ] **Step 2: Add the failing request specs for the reveal UI**

Append inside the `RSpec.describe` block of `spec/requests/dashboard_spec.rb`:

```ruby
  describe "teaching hints" do
    it "renders a locked hint before submission when a teaching_note exists" do
      ps = base_problem_set
      ps["code_review"]["teaching_note"] = "Count the queries per iteration"
      create_exercise(problem_set: ps)
      get root_path
      expect(response.body).to include("Need a nudge?")
      expect(response.body).to include("Count the queries per iteration")
      expect(response.body).to include('class="hint locked"')
    end

    it "renders the hint unlocked after submission" do
      ps = base_problem_set
      ps["pattern"]["teaching_note"] = "Think about single responsibility"
      create_response(create_exercise(problem_set: ps))
      get root_path
      expect(response.body).to include("Think about single responsibility")
      expect(response.body).not_to include('class="hint locked"')
    end

    it "renders no hint markup for exercises without teaching notes" do
      create_exercise
      get root_path
      expect(response.body).not_to include("Need a nudge?")
    end
  end
```

- [ ] **Step 3: Run both spec files to verify the new examples fail**

Run: `bundle exec rspec spec/services/claude_service_spec.rb spec/requests/dashboard_spec.rb`
Expected: the 2 service examples and the 2 hint-present examples FAIL; the no-hint example passes.

- [ ] **Step 4: Update EXERCISE_SCHEMA and the prompt**

In `app/services/claude_service.rb`, replace the whole `EXERCISE_SCHEMA` heredoc with:

```ruby
  # JSON schema the morning job expects Claude to return for a problem set
  EXERCISE_SCHEMA = <<~SCHEMA
    {
      "code_review": {
        "question": "string — what to find/fix",
        "snippet":  "string — Ruby/Rails code, ~10-15 lines",
        "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer"
      },
      "pattern": {
        "title":    "string — pattern name",
        "why":      "string — one sentence on why the pattern exists",
        "question": "string — conceptual question to answer",
        "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
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
        "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer"
      }
    }
  SCHEMA
```

In `build_exercise_prompt`, add one line to the `Instructions:` list (after the "Rotate between topics" line):

```
      - Each teaching_note must point toward how to think about the problem or the right question to ask — one or two sentences, never the full answer.
```

- [ ] **Step 5: Create the hint partial and wire it into the three sections**

Create `app/views/dashboard/_teaching_hint.html.erb`:

```erb
<% if note.present? %>
  <% locked = !submitted && answer.to_s.strip.length <= 10 %>
  <details class="hint<%= " locked" if locked %>" data-hint-for="<%= field %>">
    <summary>Need a nudge? 💡</summary>
    <div class="hint-body"><%= note %></div>
  </details>
<% end %>
```

In `app/views/dashboard/show.html.erb`:

**5a.** Add to the `<style>` block:

```css
  details.hint { margin-bottom: 1rem; }
  details.hint summary { cursor: pointer; font-size: .85rem; color: var(--accent); padding: .4rem 0; list-style: none; }
  details.hint summary::before { content: "▶ "; }
  details.hint[open] summary::before { content: "▼ "; }
  details.hint.locked { pointer-events: none; opacity: .45; }
  .hint-body { background: rgba(124,106,247,.08); border-left: 3px solid var(--accent); padding: .6rem .9rem; font-size: .9rem; border-radius: 0 6px 6px 0; margin-top: .5rem; line-height: 1.6; }
```

**5b.** In each of the three sections, render the hint immediately before the answer area (`<% if submitted %>…answer…<% end %>` block):

Section 1 (code review):
```erb
      <%= render "dashboard/teaching_hint", note: cr["teaching_note"], field: "code_review", submitted: submitted, answer: @response.answers["code_review"] %>
```

Section 2 (pattern), after the `</details>` of the reference block:
```erb
      <%= render "dashboard/teaching_hint", note: pat["teaching_note"], field: "pattern", submitted: submitted, answer: @response.answers["pattern"] %>
```

Section 3 (challenge):
```erb
      <%= render "dashboard/teaching_hint", note: ch["teaching_note"], field: "challenge", submitted: submitted, answer: @response.answers["challenge"] %>
```

**5c.** In the inline auto-save `<script>`, extend `updateProgress()` so typing unlocks hints live (same >10-char rule) — add before its closing brace:

```js
        document.querySelectorAll("details.hint[data-hint-for]").forEach(d => {
          const t = form.querySelector(`textarea[data-field="${d.dataset.hintFor}"]`);
          if (t) d.classList.toggle("locked", t.value.trim().length <= 10);
        });
```

- [ ] **Step 6: Run both spec files to verify they pass**

Run: `bundle exec rspec spec/services/claude_service_spec.rb spec/requests/dashboard_spec.rb`
Expected: all examples pass (5 dashboard + 3 hint + 2 service).

- [ ] **Step 7: Full suite + lint**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: all examples pass (37 total), no offenses.

- [ ] **Step 8: Commit**

```bash
git add spec/services/claude_service_spec.rb spec/requests/dashboard_spec.rb app/services/claude_service.rb app/views/dashboard/_teaching_hint.html.erb app/views/dashboard/show.html.erb
git commit -m "Add teaching_note per problem: schema, prompt, gated dashboard reveal

Collapsed 'Need a nudge?' hint per section, locked until that section's
answer passes the existing >10-char threshold (same heuristic as the
progress bar), always available after submission. Old exercises without
the field render unchanged."
```

---

### Task 3: Concept tagging (vocabulary, migration, copy-on-save, mastery loop)

**Files:**
- Create: `db/migrate/20260710000001_add_concept_tags_to_daily_responses.rb`
- Modify: `app/services/claude_service.rb` (CONCEPTS, schema, normalizer, prompt history + mastery loop, rating-label fix)
- Modify: `app/controllers/responses_controller.rb` (copy tags on create)
- Modify: `app/models/user.rb` (`recent_performance` gains `concepts`)
- Test: `spec/services/claude_service_spec.rb` (extend), `spec/models/user_spec.rb` (extend), `spec/requests/responses_spec.rb` (create)

**Interfaces:**
- Consumes: `create_user_with_key` / `login_as` from `spec/support/auth_helpers.rb` (Task 1); `EXERCISE_SCHEMA` shape with `teaching_note` (Task 2).
- Produces: `ClaudeService::CONCEPTS` (frozen array of 16 strings); `problem_set` sections carry `"concept"`; `daily_responses.concept_tags` jsonb column (map of section name → concept string); `User#recent_performance` hashes gain `concepts:` (that map).

**Pre-existing bug fixed here (in scope per spec section 4):** `recent_performance` returns `rating` as the enum *string* (`"too_easy"`), but `build_exercise_prompt` labels it via integer keys (`{ 0 => "too easy", … }`), so history lines always say "unrated". The mastery loop depends on ratings rendering correctly, so this task fixes the mapping to string keys.

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260710000001_add_concept_tags_to_daily_responses.rb`:

```ruby
# Denormalized copy of each answered problem's concept (from the exercise's
# problem_set jsonb), keyed by section name. Copied at answer time so
# per-user concept history is a plain column query and survives any future
# problem_set regeneration.
class AddConceptTagsToDailyResponses < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_responses, :concept_tags, :jsonb, default: {}
  end
end
```

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:test:prepare`
Expected: migration applies; `db/schema.rb` gains the column with `default: {}`.

- [ ] **Step 2: Write the failing service specs**

Append inside the `RSpec.describe ClaudeService` block of `spec/services/claude_service_spec.rb`:

```ruby
  describe "CONCEPTS" do
    it "is a frozen 16-entry vocabulary" do
      expect(ClaudeService::CONCEPTS.size).to eq(16)
      expect(ClaudeService::CONCEPTS).to be_frozen
      expect(ClaudeService::CONCEPTS).to include("n_plus_one", "transaction_safety", "error_handling")
    end
  end

  describe "EXERCISE_SCHEMA concept field" do
    it "defines a concept for each of the three sections" do
      expect(ClaudeService::EXERCISE_SCHEMA.scan('"concept"').size).to eq(3)
    end
  end

  describe "#normalize_concepts" do
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

  describe "#build_exercise_prompt with tagged history" do
    it "embeds the vocabulary, the mastery loop, and per-session concepts with correct rating labels" do
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :too_hard,
                            concept_tags: { "code_review" => "n_plus_one" })

      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include(ClaudeService::CONCEPTS.join(", "))
      expect(prompt).to include("mastery signal")
      expect(prompt).to include("concepts: n_plus_one")
      expect(prompt).to include("too hard")
      expect(prompt).not_to include("unrated")
    end
  end
```

- [ ] **Step 3: Write the failing model and request specs**

Append inside the `RSpec.describe User` block of `spec/models/user_spec.rb`:

```ruby
  describe "#recent_performance concepts" do
    it "includes each session's concept_tags map, empty for untagged history" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 },
                            concept_tags: { "code_review" => "memoization" })

      perf = user.recent_performance
      expect(perf.first[:concepts]).to eq({ "code_review" => "memoization" })
    end
  end
```

Create `spec/requests/responses_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Responses", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  def create_exercise(problem_set)
    DailyExercise.create!(user: user, date: Date.current,
                          problem_set: problem_set, generated_at: Time.current)
  end

  describe "POST /responses concept_tags copy" do
    it "copies each section's concept from the exercise onto the response" do
      create_exercise(
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern" => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "challenge" => { "title" => "t", "question" => "q", "concept" => "service_objects" }
      )

      post responses_path, params: { response: { answers: { code_review: "a" * 20 } } }

      expect(response).to have_http_status(:ok)
      expect(DailyResponse.last.concept_tags).to eq(
        "code_review" => "n_plus_one", "pattern" => "memoization", "challenge" => "service_objects"
      )
    end

    it "stores an empty map for exercises that predate tagging" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" },
                      "pattern" => { "title" => "t", "why" => "w", "question" => "q" },
                      "challenge" => { "title" => "t", "question" => "q" })

      post responses_path, params: { response: { answers: { code_review: "a" * 20 } } }

      expect(DailyResponse.last.concept_tags).to eq({})
    end
  end
end
```

- [ ] **Step 4: Run the new specs to verify they fail**

Run: `bundle exec rspec spec/services/claude_service_spec.rb spec/models/user_spec.rb spec/requests/responses_spec.rb`
Expected: new examples FAIL (`CONCEPTS` undefined, `normalize_concepts` undefined, no `concepts` key, `concept_tags` stays `{}`… the untagged-history example may pass via the column default).

- [ ] **Step 5: Implement the ClaudeService changes**

In `app/services/claude_service.rb`:

**5a.** Below `MODEL = "claude-sonnet-4-5"`, add:

```ruby
  # Fixed concept vocabulary. Embedded in the generation prompt; anything
  # Claude returns outside this list is normalized to "other" so per-user
  # concept history stays aggregatable.
  CONCEPTS = %w[
    n_plus_one transaction_safety memoization service_objects scope_chaining
    idempotency authorization background_jobs caching validations
    callbacks_vs_service query_objects policy_objects indexing concurrency
    error_handling
  ].freeze

  RATING_LABELS = { "too_easy" => "too easy", "right_level" => "right level", "too_hard" => "too hard" }.freeze
```

**5b.** In `EXERCISE_SCHEMA`, add a `"concept"` line to each of the three sections, directly after each `"teaching_note"` line:

```
        "concept": "string — exactly one concept from the provided vocabulary",
```

**5c.** In `generate_exercise`, wrap the parse:

```ruby
    normalize_concepts(parse_json_response(response.dig("content", 0, "text")))
```

**5d.** Add the private normalizer (below `parse_json_response`):

```ruby
  # Claude occasionally invents tags; keep the vocabulary closed so
  # aggregation over concept history stays clean.
  def normalize_concepts(problem_set)
    problem_set.each_value do |section|
      next unless section.is_a?(Hash) && section.key?("concept")
      section["concept"] = "other" unless CONCEPTS.include?(section["concept"])
    end
    problem_set
  end
```

**5e.** In `build_exercise_prompt`, replace the history-line block:

```ruby
      history.map { |h|
        rating_label = { 0 => "too easy", 1 => "right level", 2 => "too hard" }[h[:rating]] || "unrated"
        feedback     = h[:feedback].present? ? " | Feedback: \"#{h[:feedback]}\"" : ""
        "#{h[:date]}: #{h[:sections_answered]}/3 sections answered | #{rating_label}#{feedback}"
      }.join("\n")
```

with:

```ruby
      history.map { |h|
        rating_label = RATING_LABELS[h[:rating]] || "unrated"
        feedback     = h[:feedback].present? ? " | Feedback: \"#{h[:feedback]}\"" : ""
        concepts     = h[:concepts].respond_to?(:values) ? h[:concepts].values.compact.uniq : []
        concept_text = concepts.any? ? " | concepts: #{concepts.join(', ')}" : ""
        "#{h[:date]}: #{h[:sections_answered]}/3 sections answered | #{rating_label}#{concept_text}#{feedback}"
      }.join("\n")
```

**5f.** In the `Instructions:` block of the prompt, add after the teaching_note line (Task 2):

```
      - Choose each section's concept from this fixed vocabulary, exactly one per section: #{CONCEPTS.join(", ")}
      - Mastery loop: for any concept whose most recent rating was "too hard", reintroduce that concept in this set with a different code example and framing — same underlying concept, never a repeat of the same snippet. Keep reintroducing it in every subsequent set until the user rates a set containing it "right level" or "too easy"; that rating is the mastery signal that ends reinforcement for that concept.
      - Concepts most recently rated "too easy" must not repeat within the same week.
      - Concepts most recently rated "right level" have no special weighting.
```

- [ ] **Step 6: Copy tags on save and expose them in recent_performance**

In `app/controllers/responses_controller.rb`, in `#create`, extend the `assign_attributes` call:

```ruby
    @response.assign_attributes(
      answers:      response_params[:answers] || @response.answers,
      submitted_at: response_params[:submit] == "1" ? Time.current : @response.submitted_at,
      concept_tags: exercise_concept_tags(exercise)
    )
```

and add the private helper (below `feedback_params`):

```ruby
  def exercise_concept_tags(exercise)
    %w[code_review pattern challenge]
      .index_with { |section| exercise.problem_set.dig(section, "concept") }
      .compact
  end
```

In `app/models/user.rb`, in `recent_performance`, add `concepts:` to the mapped hash:

```ruby
        {
          date:          r.date.to_s,
          rating:        r.rating,
          feedback:      r.feedback_text,
          concepts:      r.concept_tags || {},
          sections_answered: r.answers.count { |_, v| v.to_s.length > 10 }
        }
```

- [ ] **Step 7: Run the new specs to verify they pass**

Run: `bundle exec rspec spec/services/claude_service_spec.rb spec/models/user_spec.rb spec/requests/responses_spec.rb`
Expected: all examples pass.

- [ ] **Step 8: Full suite + lint**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: all examples pass (44 total: 37 + 4 service + 1 model + 2 request), no offenses.

- [ ] **Step 9: Commit**

```bash
git add db/migrate/20260710000001_add_concept_tags_to_daily_responses.rb db/schema.rb app/services/claude_service.rb app/controllers/responses_controller.rb app/models/user.rb spec/services/claude_service_spec.rb spec/models/user_spec.rb spec/requests/responses_spec.rb
git commit -m "Concept tagging: fixed vocabulary, per-response tags, mastery loop

Each generated problem carries one concept from a 16-entry vocabulary
(off-list normalized to 'other'). Tags are copied onto
daily_responses.concept_tags (new jsonb column) at answer time, surface
in recent_performance, and drive an explicit mastery loop in the
generation prompt: too-hard concepts reintroduce every set (varied
framing) until rated right-level/too-easy; too-easy concepts don't
repeat within a week. Also fixes the history rating labels, which always
rendered 'unrated' (integer keys against enum strings)."
```
