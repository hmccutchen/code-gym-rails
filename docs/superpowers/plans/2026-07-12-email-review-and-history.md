# Email-Review Button + History Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "Email me this review" button that mails a completed AI review to the user's own address, and a `/history` page listing all past submitted responses — both driven by one shared review field map that also fixes the dashboard's broken review renderer.

**Architecture:** A `DailyResponse::AI_REVIEW_FIELDS` constant defines the review field → label mapping once. A shared HTML partial (`shared/_ai_review`) renders it on the dashboard and the new history page; a new text-only `ReviewMailer` renders the same map for email. The email action is a new member route on the existing `responses` resource; history is a new read-only controller.

**Tech Stack:** Rails 8.0.5, RSpec (request/mailer/model specs), Solid Queue via `deliver_later` (`:test` adapters in test env), no new gems.

**Spec:** `docs/superpowers/specs/2026-07-12-email-review-and-history-design.md`

## Global Constraints

- No migrations. Both features read existing columns only (`ai_review`, `answers`, `rating`, `submitted_at`, `date`). Do NOT add `review_emailed_at` — flagged in the spec and rejected.
- No changes to magic-link auth, Resend/SMTP config, or the `/test_login` route.
- No changes to concept tagging, teaching notes, feedback UI (rating buttons/feedback form), or regenerate-button/multi-provider work. The history view only *guards* for `concept_tags` via `respond_to?` — the column does not exist on this branch.
- Text-only email (no HTML template), matching the existing `magic_link.text.erb` precedent.
- Commit messages: plain imperative style matching repo history (no `feat:` prefixes), each ending with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Run tests with `bundle exec rspec <path>`; the full suite is `bundle exec rspec`.
- In request specs, never name a `DailyResponse` let `response` — that shadows the request-spec HTTP response. Use `daily_response`.

## Test Data Conventions (used across tasks)

Every request spec logs in the same way the existing `spec/requests/api_keys_spec.rb` does, and users need an `api_key` set or `ApplicationController#require_api_key` redirects to `/setup`:

```ruby
let(:user) { User.create!(email: "dev@example.com", name: "Dev", api_key: "sk-ant-api03-test") }

def login(user)
  get verify_auth_path(token: user.generate_login_token!)
end
```

`DailyExercise` requires `date`, `generated_at`, and a `problem_set`; `DailyResponse` has a unique `(user_id, date)` index, and `DailyExercise` a unique `(user_id, date)` index — one of each per user per day.

---

### Task 1: Shared review field map + partial; fix the dashboard renderer

The dashboard currently renders `feedback["summary"]` — a key `ClaudeService#build_review_prompt` never asks for (it asks for `rating`, `correct`, `missed`, `better_questions`, `next_step`, `improved_code`). This task defines the field map once, extracts a shared partial, and swaps the dashboard onto it.

**Files:**
- Modify: `app/models/daily_response.rb`
- Create: `app/views/shared/_ai_review.html.erb`
- Modify: `app/views/dashboard/show.html.erb` (review loop at lines 152–166; `<style>` block at lines 1–41)
- Modify: `app/views/layouts/application.html.erb` (`<style>` block, lines 9–37)
- Test: `spec/requests/dashboard_spec.rb` (create)

**Interfaces:**
- Consumes: `DailyResponse#ai_review` (jsonb: `{ "code_review" => { "rating" => ..., ... }, "pattern" => {...}, "challenge" => {...} }`), `DailyResponse#reviewed?`
- Produces: `DailyResponse::AI_REVIEW_FIELDS` (frozen `Hash{String => String}` of field key → display label, ordered) — Task 2's mailer template iterates it. Partial `shared/_ai_review` taking a `response:` local (a reviewed `DailyResponse`) — Task 4's history view renders it. The partial renders only the `.review-block` divs (no heading, no outer wrapper), so callers control the frame.

- [ ] **Step 1: Write the failing request spec**

Create `spec/requests/dashboard_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  let(:user) { User.create!(email: "dev@example.com", name: "Dev", api_key: "sk-ant-api03-test") }

  def login(user)
    get verify_auth_path(token: user.generate_login_token!)
  end

  let(:exercise) do
    user.daily_exercises.create!(
      date: Date.current,
      generated_at: Time.current,
      problem_set: {
        code_review: { question: "Spot the bug", snippet: "def a; end" },
        pattern:     { title: "Service Objects", why: "Encapsulation", question: "When?", reference: {} },
        challenge:   { question: "Build it", starter_code: "" }
      }
    )
  end

  let(:ai_review) do
    {
      "code_review" => {
        "rating"           => "solid",
        "correct"          => "You spotted the N+1 query",
        "missed"           => "The missing index on user_id",
        "better_questions" => "What happens under concurrent writes?",
        "next_step"        => "Read about partial indexes",
        "improved_code"    => "User.includes(:posts)"
      },
      "pattern"   => { "rating" => "developing", "correct" => "Good definition", "missed" => "Tradeoffs", "better_questions" => "When not to use it?", "next_step" => "Refactor a fat controller", "improved_code" => "" },
      "challenge" => { "rating" => "strong", "correct" => "Clean implementation", "missed" => "Empty-input edge case", "better_questions" => "Is this idempotent?", "next_step" => "Add a guard clause", "improved_code" => "" }
    }
  end

  let!(:daily_response) do
    user.daily_responses.create!(
      daily_exercise: exercise,
      date: Date.current,
      answers: { code_review: "Found the N+1 in the loop", pattern: "Use for multi-step writes", challenge: "def call; end" },
      submitted_at: Time.current,
      ai_review: ai_review
    )
  end

  describe "GET / with a reviewed response" do
    it "renders every populated review field, not just improved_code" do
      login(user)
      get root_path

      expect(response.body).to include("What you got right")
      expect(response.body).to include("You spotted the N+1 query")
      expect(response.body).to include("What you missed")
      expect(response.body).to include("The missing index on user_id")
      expect(response.body).to include("Questions to ask yourself")
      expect(response.body).to include("Next step")
      expect(response.body).to include("User.includes(:posts)")
    end

    it "skips blank fields (no empty improved_code block for text sections)" do
      login(user)
      get root_path

      # Pattern/challenge sections have improved_code: "" — exactly one <pre> from review blocks
      expect(response.body.scan("User.includes(:posts)").size).to eq(1)
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: FAIL — the first example can't find `"What you got right"` (current view renders `feedback["summary"]`, which is absent).

- [ ] **Step 3: Add `AI_REVIEW_FIELDS` to `DailyResponse`**

In `app/models/daily_response.rb`, after the `validates :date` line:

```ruby
  # Ordered field → label map for rendering ai_review sections. Shared by the
  # shared/_ai_review partial and ReviewMailer so the copy lives in one place.
  # "summary" is legacy: reviews saved before the current schema may carry it.
  AI_REVIEW_FIELDS = {
    "rating"           => "Rating",
    "summary"          => "Summary",
    "correct"          => "What you got right",
    "missed"           => "What you missed",
    "better_questions" => "Questions to ask yourself",
    "next_step"        => "Next step"
  }.freeze
```

- [ ] **Step 4: Create the shared partial**

Create `app/views/shared/_ai_review.html.erb` (blocks only — callers supply the heading/wrapper):

```erb
<% response.ai_review.each do |section, feedback| %>
  <div class="review-block">
    <h4><%= section.humanize %></h4>
    <% DailyResponse::AI_REVIEW_FIELDS.each do |key, label| %>
      <% next if feedback[key].blank? %>
      <p style="font-size:.9rem;line-height:1.7"><strong><%= label %>:</strong> <%= feedback[key] %></p>
    <% end %>
    <% if feedback["improved_code"].present? %>
      <pre class="snippet" style="margin-top:.75rem"><code><%= feedback["improved_code"] %></code></pre>
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 5: Swap the dashboard onto the partial and relocate shared CSS**

In `app/views/dashboard/show.html.erb`, replace the AI Review display block (currently lines 152–166):

```erb
      <%# AI Review display %>
      <% if @response.reviewed? %>
        <div class="review-section">
          <h3 style="font-size:1rem;margin-bottom:.75rem">Claude's Review</h3>
          <%= render "shared/ai_review", response: @response %>
        </div>
      <% end %>
```

Move these three rules out of the dashboard `<style>` block (delete them there) and into the layout `<style>` block in `app/views/layouts/application.html.erb`, after the `.btn-sm` rule — the history page (Task 4) needs them too:

```css
    pre.snippet { background: #0d0d1a; border: 1px solid var(--border); border-radius: 6px; padding: 1rem; font-size: .85rem; overflow-x: auto; margin-bottom: 1rem; white-space: pre; }
    .review-block { background: rgba(124,106,247,.06); border: 1px solid var(--border); border-radius: 6px; padding: 1rem; margin-top: .75rem; }
    .review-block h4 { color: var(--accent); font-size: .85rem; text-transform: uppercase; letter-spacing: .06em; margin-bottom: .5rem; }
```

Leave `.review-section` in the dashboard's style block (only the dashboard uses that wrapper). Everything else in the dashboard `<style>` block stays put.

- [ ] **Step 6: Run the spec to verify it passes**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: 2 examples, 0 failures.

- [ ] **Step 7: Run the full suite (regression check on the CSS/view move)**

Run: `bundle exec rspec`
Expected: 0 failures.

- [ ] **Step 8: Commit**

```bash
git add app/models/daily_response.rb app/views/shared/_ai_review.html.erb app/views/dashboard/show.html.erb app/views/layouts/application.html.erb spec/requests/dashboard_spec.rb
git commit -m "Fix review renderer: shared field map + partial for ai_review

The dashboard rendered ai_review['summary'], a key the review schema
never produces, silently dropping rating/correct/missed/
better_questions/next_step. Field labels now live once in
DailyResponse::AI_REVIEW_FIELDS, rendered by shared/_ai_review
(reused by the history page and mailer in follow-up commits).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `ReviewMailer#send_review`

**Files:**
- Create: `app/mailers/review_mailer.rb`
- Create: `app/views/review_mailer/send_review.text.erb`
- Test: `spec/mailers/review_mailer_spec.rb` (create)

**Interfaces:**
- Consumes: `DailyResponse::AI_REVIEW_FIELDS` (Task 1), `DailyResponse#ai_review`, `#user`, `#date`; `ApplicationMailer` (`default from: ENV.fetch("MAIL_FROM", ...)`, layout "mailer")
- Produces: `ReviewMailer.send_review(daily_response)` → `Mail::Message` — Task 3's controller calls `ReviewMailer.send_review(@response).deliver_later`. Positional AR argument (GlobalID-serialized by `deliver_later`), matching the `UserMailer.magic_link(user, raw_token)` precedent.

- [ ] **Step 1: Write the failing mailer spec**

Create `spec/mailers/review_mailer_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ReviewMailer, type: :mailer do
  describe "#send_review" do
    let(:user) { User.create!(email: "dev@example.com", name: "Dev") }

    let(:exercise) do
      user.daily_exercises.create!(
        date: Date.new(2026, 7, 10),
        generated_at: Time.current,
        problem_set: { code_review: { question: "q", snippet: "s" } }
      )
    end

    let(:daily_response) do
      user.daily_responses.create!(
        daily_exercise: exercise,
        date: Date.new(2026, 7, 10),
        answers: { code_review: "Found the N+1 in the loop" },
        submitted_at: Time.current,
        ai_review: {
          "code_review" => {
            "rating"           => "solid",
            "correct"          => "You spotted the N+1 query",
            "missed"           => "The missing index on user_id",
            "better_questions" => "What happens under concurrent writes?",
            "next_step"        => "Read about partial indexes",
            "improved_code"    => "User.includes(:posts)"
          }
        }
      )
    end

    let(:mail) { ReviewMailer.send_review(daily_response) }

    it "addresses the user with a dated subject" do
      expect(mail.to).to eq([ "dev@example.com" ])
      expect(mail.subject).to eq("Your Code Gym review — Friday, July 10")
    end

    it "renders every populated field with its label" do
      body = mail.body.encoded
      expect(body).to include("Code review")
      expect(body).to include("Rating: solid")
      expect(body).to include("What you got right: You spotted the N+1 query")
      expect(body).to include("What you missed: The missing index on user_id")
      expect(body).to include("Questions to ask yourself: What happens under concurrent writes?")
      expect(body).to include("Next step: Read about partial indexes")
      expect(body).to include("Improved code:")
      expect(body).to include("User.includes(:posts)")
    end

    it "skips blank fields" do
      daily_response.ai_review["code_review"]["improved_code"] = ""
      daily_response.ai_review["code_review"]["missed"] = ""
      expect(mail.body.encoded).not_to include("Improved code:")
      expect(mail.body.encoded).not_to include("What you missed:")
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/mailers/review_mailer_spec.rb`
Expected: FAIL with `uninitialized constant ReviewMailer`.

- [ ] **Step 3: Create the mailer**

Create `app/mailers/review_mailer.rb`:

```ruby
class ReviewMailer < ApplicationMailer
  # On-demand copy of a completed AI review, sent to the user's own address.
  def send_review(daily_response)
    @response = daily_response
    mail(
      to:      daily_response.user.email,
      subject: "Your Code Gym review — #{daily_response.date.strftime('%A, %B %-d')}"
    )
  end
end
```

- [ ] **Step 4: Create the text template**

Create `app/views/review_mailer/send_review.text.erb` (text-only, like `user_mailer/magic_link.text.erb`; `-%>` trims the ERB scaffolding lines):

```erb
Hi <%= @response.user.name %>,

Here's your Code Gym review from <%= @response.date.strftime("%A, %B %-d, %Y") %>.

<% @response.ai_review.each do |section, feedback| -%>
== <%= section.humanize %> ==

<% DailyResponse::AI_REVIEW_FIELDS.each do |key, label| -%>
<% next if feedback[key].blank? -%>
<%= label %>: <%= feedback[key] %>

<% end -%>
<% if feedback["improved_code"].present? -%>
Improved code:

<%= feedback["improved_code"] %>

<% end -%>
<% end -%>
— Code Gym
```

- [ ] **Step 5: Run the spec to verify it passes**

Run: `bundle exec rspec spec/mailers/review_mailer_spec.rb`
Expected: 3 examples, 0 failures. If the subject assertion fails on the weekday name, the assertion is wrong, not the code — 2026-07-10 is a Friday; don't "fix" it by loosening the format.

- [ ] **Step 6: Commit**

```bash
git add app/mailers/review_mailer.rb app/views/review_mailer/send_review.text.erb spec/mailers/review_mailer_spec.rb
git commit -m "Add ReviewMailer#send_review: text-only email of a completed AI review

Iterates DailyResponse::AI_REVIEW_FIELDS so the email and the inline
renderer share one field map.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `email_review` route, controller action, and dashboard button

**Files:**
- Modify: `config/routes.rb` (the `resources :responses` member block)
- Modify: `app/controllers/responses_controller.rb`
- Modify: `app/views/dashboard/show.html.erb` (the review-section block from Task 1 Step 5)
- Test: `spec/requests/responses_spec.rb` (create)

**Interfaces:**
- Consumes: `ReviewMailer.send_review(daily_response)` (Task 2), `DailyResponse#reviewed?`, the existing `set_response` before_action (scopes lookups to `current_user.daily_responses`)
- Produces: `POST /responses/:id/email_review` (`email_review_response_path`), used only by the dashboard button.

- [ ] **Step 1: Write the failing request spec**

Create `spec/requests/responses_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Responses", type: :request do
  let(:user)  { User.create!(email: "dev@example.com", name: "Dev", api_key: "sk-ant-api03-test") }
  let(:other) { User.create!(email: "other@example.com", name: "Other", api_key: "sk-ant-api03-test") }

  def login(user)
    get verify_auth_path(token: user.generate_login_token!)
  end

  def create_response_for(owner, reviewed: true)
    exercise = owner.daily_exercises.create!(
      date: Date.current,
      generated_at: Time.current,
      problem_set: { code_review: { question: "q", snippet: "s" } }
    )
    owner.daily_responses.create!(
      daily_exercise: exercise,
      date: Date.current,
      answers: { code_review: "Found the N+1 in the loop" },
      submitted_at: Time.current,
      ai_review: reviewed ? { "code_review" => { "rating" => "solid", "correct" => "Spotted it" } } : nil
    )
  end

  describe "POST /responses/:id/email_review" do
    it "requires login" do
      daily_response = create_response_for(user)
      post email_review_response_path(daily_response)
      expect(response).to redirect_to(login_path)
    end

    it "404s for another user's response" do
      daily_response = create_response_for(other)
      login(user)

      post email_review_response_path(daily_response)

      # set_response scopes to current_user.daily_responses → RecordNotFound,
      # which test env's show_exceptions = :rescuable renders as a 404.
      expect(response).to have_http_status(:not_found)
    end

    it "redirects with an alert when there is no review yet" do
      daily_response = create_response_for(user, reviewed: false)
      login(user)

      expect {
        post email_review_response_path(daily_response)
      }.not_to have_enqueued_mail(ReviewMailer, :send_review)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("No review to email yet.")
    end

    it "enqueues the review email and confirms with the user's address" do
      daily_response = create_response_for(user)
      login(user)

      expect {
        post email_review_response_path(daily_response)
      }.to have_enqueued_mail(ReviewMailer, :send_review).with(daily_response)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq("Review sent to dev@example.com.")
    end
  end
end
```

(Note: unhandled `ActiveRecord::RecordNotFound` from `set_response` is the existing behavior for `#review`/`#feedback` too — no new error handling; the 404 comes from Rails' default rescuable mapping.)

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/requests/responses_spec.rb`
Expected: FAIL with `undefined method 'email_review_response_path'` (route doesn't exist yet).

- [ ] **Step 3: Add the route**

In `config/routes.rb`, extend the existing member block:

```ruby
  resources :responses, only: [ :create ] do
    member do
      patch :feedback     # rating + feedback_text after submission
      post  :review       # trigger Claude inline review
      post  :email_review # email the completed review to the user
    end
  end
```

- [ ] **Step 4: Add the controller action**

In `app/controllers/responses_controller.rb`, extend the before_action:

```ruby
  before_action :set_response, only: [ :feedback, :review, :email_review ]
```

Add after the `review` action:

```ruby
  # POST /responses/:id/email_review — email the completed review to the user
  def email_review
    return redirect_to root_path, alert: "No review to email yet." unless @response.reviewed?

    ReviewMailer.send_review(@response).deliver_later
    redirect_to root_path, notice: "Review sent to #{current_user.email}."
  end
```

- [ ] **Step 5: Run the spec to verify it passes**

Run: `bundle exec rspec spec/requests/responses_spec.rb`
Expected: 4 examples, 0 failures.

- [ ] **Step 6: Add the dashboard button**

In `app/views/dashboard/show.html.erb`, replace the review-section block (as written in Task 1 Step 5) with a heading row that carries the button:

```erb
      <%# AI Review display %>
      <% if @response.reviewed? %>
        <div class="review-section">
          <div style="display:flex;justify-content:space-between;align-items:center;">
            <h3 style="font-size:1rem">Claude's Review</h3>
            <%= button_to "Email me this review", email_review_response_path(@response), method: :post, class: "btn btn-ghost btn-sm" %>
          </div>
          <%= render "shared/ai_review", response: @response %>
        </div>
      <% end %>
```

- [ ] **Step 7: Run dashboard + responses specs to verify nothing broke**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb spec/requests/responses_spec.rb`
Expected: 6 examples, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add config/routes.rb app/controllers/responses_controller.rb app/views/dashboard/show.html.erb spec/requests/responses_spec.rb
git commit -m "Add 'Email me this review' button on completed reviews

POST /responses/:id/email_review enqueues ReviewMailer via
deliver_later (Solid Queue) and confirms with a flash notice, so the
click never blocks on Resend.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: History page (`/history`) + nav link

**Files:**
- Modify: `app/models/daily_response.rb` (extract `answered_sections`, DRY up `completeness`)
- Create: `app/controllers/history_controller.rb`
- Create: `app/views/history/index.html.erb`
- Modify: `config/routes.rb`
- Modify: `app/views/layouts/application.html.erb` (nav-links block, ~line 44)
- Test: `spec/models/daily_response_spec.rb` (create), `spec/requests/history_spec.rb` (create)

**Interfaces:**
- Consumes: partial `shared/_ai_review` with `response:` local (Task 1); layout CSS `pre.snippet` / `.review-block` (Task 1); `ApplicationController` auth before_actions
- Produces: `GET /history` (`history_path`); `DailyResponse#answered_sections` → `Array[String]` of answer keys whose value is >10 chars stripped (e.g. `["code_review", "pattern"]`).

- [ ] **Step 1: Write the failing model spec for `answered_sections`**

Create `spec/models/daily_response_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe DailyResponse, type: :model do
  let(:user) { User.create!(email: "dev@example.com", name: "Dev") }

  let(:exercise) do
    user.daily_exercises.create!(
      date: Date.current,
      generated_at: Time.current,
      problem_set: { code_review: { question: "q", snippet: "s" } }
    )
  end

  describe "#answered_sections" do
    it "returns keys whose answers have substance (>10 chars), preserving the >10-char completeness heuristic" do
      daily_response = user.daily_responses.create!(
        daily_exercise: exercise,
        date: Date.current,
        answers: { code_review: "Found the N+1 in the loop", pattern: "short", challenge: "" }
      )

      expect(daily_response.answered_sections).to eq([ "code_review" ])
      expect(daily_response.completeness).to eq(33)
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/models/daily_response_spec.rb`
Expected: FAIL with `undefined method 'answered_sections'`.

- [ ] **Step 3: Extract `answered_sections` in the model**

In `app/models/daily_response.rb`, replace the existing `completeness` method:

```ruby
  # Answer keys with substantive content — same >10-char heuristic the
  # dashboard progress bar uses.
  def answered_sections
    answers.select { |_, v| v.to_s.strip.length > 10 }.keys
  end

  def completeness
    (answered_sections.size / 3.0 * 100).round
  end
```

- [ ] **Step 4: Run the model spec to verify it passes**

Run: `bundle exec rspec spec/models/daily_response_spec.rb`
Expected: 1 example, 0 failures.

- [ ] **Step 5: Write the failing history request spec**

Create `spec/requests/history_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "History", type: :request do
  let(:user)  { User.create!(email: "dev@example.com", name: "Dev", api_key: "sk-ant-api03-test") }
  let(:other) { User.create!(email: "other@example.com", name: "Other", api_key: "sk-ant-api03-test") }

  def login(user)
    get verify_auth_path(token: user.generate_login_token!)
  end

  def create_session_for(owner, date:, submitted: true, reviewed: false, rating: nil)
    exercise = owner.daily_exercises.create!(
      date: date,
      generated_at: Time.current,
      problem_set: { code_review: { question: "q-#{date}", snippet: "s" } }
    )
    owner.daily_responses.create!(
      daily_exercise: exercise,
      date: date,
      answers: { code_review: "Answer with plenty of substance for #{date}" },
      submitted_at: submitted ? Time.current : nil,
      rating: rating,
      ai_review: reviewed ? { "code_review" => { "rating" => "solid", "correct" => "Spotted the issue on #{date}" } } : nil
    )
  end

  describe "GET /history" do
    it "requires login" do
      get history_path
      expect(response).to redirect_to(login_path)
    end

    it "lists only the current user's submitted responses, newest first" do
      old   = create_session_for(user, date: 3.days.ago.to_date, reviewed: true, rating: :too_hard)
      newer = create_session_for(user, date: 1.day.ago.to_date)
      create_session_for(user, date: Date.current, submitted: false)   # draft — excluded
      create_session_for(other, date: 2.days.ago.to_date)              # other user — excluded

      login(user)
      get history_path

      expect(response.body).to include(newer.date.strftime("%A, %B %-d, %Y"))
      expect(response.body).to include(old.date.strftime("%A, %B %-d, %Y"))
      expect(response.body).not_to include(Date.current.strftime("%A, %B %-d, %Y"))
      expect(response.body).not_to include(2.days.ago.to_date.strftime("%A, %B %-d, %Y"))
      expect(response.body.index(newer.date.strftime("%A, %B %-d, %Y")))
        .to be < response.body.index(old.date.strftime("%A, %B %-d, %Y"))
    end

    it "shows rating, review content for reviewed entries, and a fallback otherwise" do
      create_session_for(user, date: 3.days.ago.to_date, reviewed: true, rating: :too_hard)
      create_session_for(user, date: 1.day.ago.to_date)

      login(user)
      get history_path

      expect(response.body).to include("Too hard")
      expect(response.body).to include("What you got right")
      expect(response.body).to include("Spotted the issue on #{3.days.ago.to_date}")
      expect(response.body).to include("No AI review requested.")
      expect(response.body).to include("1/3 sections")
    end
  end
end
```

- [ ] **Step 6: Run the spec to verify it fails**

Run: `bundle exec rspec spec/requests/history_spec.rb`
Expected: FAIL with `undefined method 'history_path'`.

- [ ] **Step 7: Add the route**

In `config/routes.rb`, after `root "dashboard#show"`:

```ruby
  # Past sessions, newest first
  get "history", to: "history#index"
```

- [ ] **Step 8: Create the controller**

Create `app/controllers/history_controller.rb`:

```ruby
class HistoryController < ApplicationController
  # GET /history — all past submitted sessions, newest first. Drafts
  # (auto-saved but unsubmitted) stay on the dashboard, not here.
  def index
    @responses = current_user.daily_responses
                             .where.not(submitted_at: nil)
                             .includes(:daily_exercise)
                             .order(date: :desc)
  end
end
```

- [ ] **Step 9: Create the view**

Create `app/views/history/index.html.erb`. The `respond_to?(:concept_tags)` guard is deliberate: the column only exists on the unmerged `feedback-teaching-tagging` branch (jsonb map of section → concept slug); on this branch the block is skipped. Do not add the column.

```erb
<style>
  .page-header { margin-bottom: 2rem; }
  .page-header h1 { font-size: 1.5rem; }
  .page-header .count { color: var(--muted); font-size: .9rem; }

  .history-entry { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 1.5rem; margin-bottom: 1.5rem; }
  .history-entry h2 { font-size: 1.05rem; margin-bottom: .5rem; }
  .history-meta { display: flex; gap: .75rem; flex-wrap: wrap; align-items: center; font-size: .85rem; color: var(--muted); margin-bottom: .5rem; }
  .history-pill { border: 1px solid var(--border); border-radius: 4px; padding: .15rem .5rem; }
  .history-tag { border: 1px solid var(--accent); color: var(--accent); border-radius: 4px; padding: .15rem .5rem; font-size: .8rem; }

  details.review summary { cursor: pointer; font-size: .85rem; color: var(--accent); padding: .4rem 0; list-style: none; }
  details.review summary::before { content: "▶ "; }
  details.review[open] summary::before { content: "▼ "; }
  .no-review { font-size: .85rem; color: var(--muted); }
</style>

<div class="page-header">
  <h1>History</h1>
  <div class="count"><%= pluralize(@responses.size, "submitted session") %></div>
</div>

<% if @responses.empty? %>
  <div class="history-entry" style="text-align:center;padding:3rem;">
    <p style="color:var(--muted);">No submitted sessions yet. <%= link_to "Back to today's gym", root_path %></p>
  </div>
<% end %>

<% @responses.each_with_index do |daily_response, i| %>
  <div class="history-entry">
    <h2><%= daily_response.date.strftime("%A, %B %-d, %Y") %></h2>

    <div class="history-meta">
      <span class="history-pill">
        <%= daily_response.answered_sections.size %>/3 sections<% if daily_response.answered_sections.any? %> — <%= daily_response.answered_sections.map(&:humanize).join(", ") %><% end %>
      </span>
      <% if daily_response.rating.present? %>
        <span class="history-pill">Rated: <%= daily_response.rating.humanize %></span>
      <% end %>
      <% if daily_response.respond_to?(:concept_tags) && daily_response.concept_tags.present? %>
        <% daily_response.concept_tags.values.uniq.each do |tag| %>
          <span class="history-tag"><%= tag.humanize %></span>
        <% end %>
      <% end %>
    </div>

    <% if daily_response.reviewed? %>
      <details class="review" <%= "open" if i.zero? %>>
        <summary>Claude's review</summary>
        <%= render "shared/ai_review", response: daily_response %>
      </details>
    <% else %>
      <p class="no-review">No AI review requested.</p>
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 10: Add the nav link**

In `app/views/layouts/application.html.erb`, in the logged-in nav-links block:

```erb
        <div class="nav-links">
          <span><%= current_user.name %></span>
          <%= link_to "History", history_path %>
          <%= button_to "Log out", logout_path, method: :delete, class: "btn btn-ghost btn-sm" %>
        </div>
```

- [ ] **Step 11: Run the history spec to verify it passes**

Run: `bundle exec rspec spec/requests/history_spec.rb`
Expected: 3 examples, 0 failures.

- [ ] **Step 12: Run the full suite**

Run: `bundle exec rspec`
Expected: 0 failures across all specs (models, requests, mailers).

- [ ] **Step 13: Commit**

```bash
git add app/models/daily_response.rb app/controllers/history_controller.rb app/views/history/index.html.erb config/routes.rb app/views/layouts/application.html.erb spec/models/daily_response_spec.rb spec/requests/history_spec.rb
git commit -m "Add /history page listing past submitted sessions

Newest first, submitted-only (drafts stay on the dashboard). Reuses
shared/_ai_review with reviews collapsed behind <details> (newest
open). Guards for concept_tags via respond_to? so the unmerged
tagging branch lights up here without changes. No pagination yet —
~22 entries/month; revisit with Pagy when volume warrants.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Verification (after all tasks)

- `bundle exec rspec` — full suite green.
- Manual smoke via `bin/dev` if desired: submit today's answers, request a review, click "Email me this review" (letter_opener shows the text email in dev), visit `/history` from the nav link.
