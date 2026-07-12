# Email-Review Button + History Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Revision (2026-07-12):** rewritten against `origin/main` (`3eac43f`, post-PR #13), which merged the feedback-teaching-tagging work after the original plan was drafted. PR #13 already fixed the dashboard's `ai_review["summary"]` rendering bug (commit `7a84905`) with an inline field map, added `concept_tags` to `daily_responses`, added `spec/requests/dashboard_spec.rb` / `spec/requests/responses_spec.rb`, and added shared request-spec helpers. Task 1 is now a behavior-preserving extraction; Tasks 3–4 extend the existing spec files and render tags for real.

**Goal:** Add an "Email me this review" button that mails a completed AI review to the user's own address, and a `/history` page listing all past submitted responses — both driven by one shared review field map extracted from the dashboard's inline renderer.

**Architecture:** A `DailyResponse::AI_REVIEW_FIELDS` constant holds the review field → label mapping currently inlined in `dashboard/show.html.erb`. A shared HTML partial (`shared/_ai_review`) renders it on the dashboard and the new history page; a new text-only `ReviewMailer` renders the same map for email. The email action is a new member route on the existing `responses` resource; history is a new read-only controller.

**Tech Stack:** Rails 8.0.5, RSpec (request/mailer/model specs), Solid Queue via `deliver_later` (`:test` adapters in test env), no new gems.

**Spec:** `docs/superpowers/specs/2026-07-12-email-review-and-history-design.md` (see its revision note)

## Global Constraints

- No migrations. Both features read existing columns (`ai_review`, `answers`, `rating`, `submitted_at`, `date`, `concept_tags`). Do NOT add `review_emailed_at` — flagged in the spec and rejected.
- No changes to magic-link auth, Resend/SMTP config, or the `/test_login` route.
- No changes to concept tagging, teaching notes/hints, or the feedback UI. In particular, the two `<%= render "responses/feedback_form", ... %>` lines in `dashboard/show.html.erb` and the review re-gating around them must be preserved exactly as-is.
- The extraction in Task 1 is behavior-preserving: the dashboard's rendered review HTML (classes `review-block`, `review-rating`, `review-item`, the rating badge inside the `h4`, the `fb.is_a?(Hash)` guard) must not change. `spec/requests/dashboard_spec.rb` pins this.
- Text-only email (no HTML template), matching the existing `magic_link.text.erb` precedent.
- Request specs use the existing `spec/support/auth_helpers.rb` helpers: `create_user_with_key(email:, name:)` and `login_as(user)`.
- Commit messages: plain imperative style matching repo history (no `feat:` prefixes), each ending with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Run tests with `bundle exec rspec <path>`; the full suite is `bundle exec rspec` (46 examples green at base).
- In request specs, never name a `DailyResponse` variable `response` — that shadows the request-spec HTTP response. Use `daily_response` (or `resp`, as the existing specs do).

## Test Data Conventions

`DailyExercise` requires `date`, `generated_at`, and a `problem_set`; both `daily_exercises` and `daily_responses` have a unique `(user_id, date)` index — one of each per user per day. `concept_tags` is jsonb, NOT NULL, default `{}`, a map of section → concept slug (e.g. `{ "code_review" => "n_plus_one" }`).

---

### Task 1: Extract shared review field map + partial (behavior-preserving)

The dashboard renders `ai_review` correctly (fixed in PR #13) but the field → label map and markup are inlined in the view at `app/views/dashboard/show.html.erb:168-188`. The history page (Task 4) and the mailer (Task 2) need the same mapping, so extract it without changing rendered output.

**Files:**
- Modify: `app/models/daily_response.rb`
- Create: `app/views/shared/_ai_review.html.erb`
- Modify: `app/views/dashboard/show.html.erb` (review block at lines 168–188; `<style>` rules at lines 11, 35–36, 45–46)
- Modify: `app/views/layouts/application.html.erb` (`<style>` block, after the `.btn-sm` rule at line 36)
- Test: existing `spec/requests/dashboard_spec.rb` (no changes — it pins the behavior)

**Interfaces:**
- Consumes: `DailyResponse#ai_review` (jsonb: `{ "code_review" => { "rating" => ..., "correct" => ..., ... }, ... }`)
- Produces: `DailyResponse::AI_REVIEW_FIELDS` (frozen ordered `Hash{String => String}`: `correct`, `missed`, `better_questions`, `next_step` → labels) — Task 2's mailer template iterates it; `rating` and `improved_code` are deliberately NOT in the map (rating renders as a badge / its own email line, improved_code as a code block). Partial `shared/_ai_review` taking a `response:` local (a reviewed `DailyResponse`) rendering only the `.review-block` divs — callers supply the heading and wrapper. Task 4's history view renders it.

- [ ] **Step 1: Confirm the pinning spec is green before touching anything**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: 9 examples, 0 failures.

- [ ] **Step 2: Add `AI_REVIEW_FIELDS` to `DailyResponse`**

In `app/models/daily_response.rb`, after the `validates :date` line:

```ruby
  # Ordered field → label map for rendering ai_review sections — shared by the
  # shared/_ai_review partial and ReviewMailer so the copy lives in one place.
  # "rating" (badge) and "improved_code" (code block) render separately.
  AI_REVIEW_FIELDS = {
    "correct"          => "What you got right",
    "missed"           => "What you missed",
    "better_questions" => "Questions to ask yourself",
    "next_step"        => "Next step"
  }.freeze
```

- [ ] **Step 3: Create the shared partial**

Create `app/views/shared/_ai_review.html.erb` — this is the exact inner loop currently at `dashboard/show.html.erb:171-187`, with the inline hash replaced by the constant:

```erb
<% response.ai_review.each do |section, fb| %>
  <% next unless fb.is_a?(Hash) %>
  <div class="review-block">
    <h4><%= section.humanize %><% if fb["rating"].present? %><span class="review-rating"><%= fb["rating"] %></span><% end %></h4>
    <% DailyResponse::AI_REVIEW_FIELDS.each do |key, label| %>
      <% if fb[key].present? %>
        <p class="review-item"><strong><%= label %>:</strong> <%= fb[key] %></p>
      <% end %>
    <% end %>
    <% if fb["improved_code"].present? %>
      <pre class="snippet" style="margin-top:.75rem"><code><%= fb["improved_code"] %></code></pre>
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 4: Swap the dashboard onto the partial and relocate shared CSS**

In `app/views/dashboard/show.html.erb`, replace lines 168–188 (the `if @response.reviewed?` review-section block **up to but NOT including** the `<%= render "responses/feedback_form", response: @response, style: :prominent %>` line — that line and the surrounding `else`/`end` gating stay exactly as they are):

```erb
    <% if @response.reviewed? %>
      <div class="review-section">
        <h3 style="font-size:1rem;margin-bottom:.75rem">Claude's Review</h3>
        <%= render "shared/ai_review", response: @response %>
      </div>
```

Move these five rules out of the dashboard `<style>` block (delete them there) into the layout `<style>` block in `app/views/layouts/application.html.erb`, after the `.btn-sm` rule — the history page (Task 4) needs them too:

```css
    pre.snippet { background: #0d0d1a; border: 1px solid var(--border); border-radius: 6px; padding: 1rem; font-size: .85rem; overflow-x: auto; margin-bottom: 1rem; white-space: pre; }
    .review-block { background: rgba(124,106,247,.06); border: 1px solid var(--border); border-radius: 6px; padding: 1rem; margin-top: .75rem; }
    .review-block h4 { color: var(--accent); font-size: .85rem; text-transform: uppercase; letter-spacing: .06em; margin-bottom: .5rem; }
    .review-rating { display: inline-block; background: rgba(124,106,247,.15); border-radius: 4px; padding: .1rem .5rem; font-size: .75rem; margin-left: .5rem; text-transform: none; letter-spacing: 0; }
    .review-item { font-size: .9rem; line-height: 1.7; margin-top: .4rem; }
```

Leave `.review-section` in the dashboard's style block (only the dashboard uses that wrapper). Everything else in the dashboard `<style>` block stays put.

- [ ] **Step 5: Verify the pinning spec still passes**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: 9 examples, 0 failures — including "renders the review with the keys review_response actually returns" and the `review-rating` badge assertion.

- [ ] **Step 6: Run the full suite (regression check on the CSS/view move)**

Run: `bundle exec rspec`
Expected: 46 examples, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add app/models/daily_response.rb app/views/shared/_ai_review.html.erb app/views/dashboard/show.html.erb app/views/layouts/application.html.erb
git commit -m "Extract ai_review rendering into shared field map + partial

Behavior-preserving: the dashboard's inline field->label hash moves to
DailyResponse::AI_REVIEW_FIELDS and the review-block loop to
shared/_ai_review, so the history page and ReviewMailer (follow-up
commits) reuse one mapping instead of forking the markup. Shared CSS
moves to the layout.

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
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
      )
    end

    let(:daily_response) do
      user.daily_responses.create!(
        daily_exercise: exercise,
        date: Date.new(2026, 7, 10),
        answers: { "code_review" => "Found the N+1 in the loop" },
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

Create `app/views/review_mailer/send_review.text.erb` (text-only, like `user_mailer/magic_link.text.erb`; `-%>` trims the ERB scaffolding lines; same `fb.is_a?(Hash)` guard and field map as the shared partial):

```erb
Hi <%= @response.user.name %>,

Here's your Code Gym review from <%= @response.date.strftime("%A, %B %-d, %Y") %>.

<% @response.ai_review.each do |section, fb| -%>
<% next unless fb.is_a?(Hash) -%>
== <%= section.humanize %> ==

<% if fb["rating"].present? -%>
Rating: <%= fb["rating"] %>

<% end -%>
<% DailyResponse::AI_REVIEW_FIELDS.each do |key, label| -%>
<% next if fb[key].blank? -%>
<%= label %>: <%= fb[key] %>

<% end -%>
<% if fb["improved_code"].present? -%>
Improved code:

<%= fb["improved_code"] %>

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
- Modify: `app/views/dashboard/show.html.erb` (the review-section block as it stands after Task 1)
- Test: `spec/requests/responses_spec.rb` (extend — this file already exists with concept_tags tests; add a new describe block, do not touch the existing ones)

**Interfaces:**
- Consumes: `ReviewMailer.send_review(daily_response)` (Task 2), `DailyResponse#reviewed?`, the existing `set_response` before_action (scopes lookups to `current_user.daily_responses`), spec helpers `create_user_with_key` / `login_as`
- Produces: `POST /responses/:id/email_review` (`email_review_response_path`), used only by the dashboard button.

- [ ] **Step 1: Extend the request spec with a failing describe block**

Append to `spec/requests/responses_spec.rb`, inside the top-level `RSpec.describe "Responses"` block (note: the file has a top-level `before { login_as(user) }`, so the requires-login example logs out first):

```ruby
  describe "POST /responses/:id/email_review" do
    def create_reviewed_response(owner, reviewed: true)
      exercise = DailyExercise.create!(
        user: owner, date: Date.current,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } },
        generated_at: Time.current
      )
      DailyResponse.create!(
        user: owner, daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "a" * 20 },
        submitted_at: Time.current,
        ai_review: reviewed ? { "code_review" => { "rating" => "solid", "correct" => "Spotted it" } } : nil
      )
    end

    it "requires login" do
      daily_response = create_reviewed_response(user)
      delete logout_path
      post email_review_response_path(daily_response)
      expect(response).to redirect_to(login_path)
    end

    it "404s for another user's response" do
      other = create_user_with_key(email: "other@example.com", name: "Other")
      daily_response = create_reviewed_response(other)

      post email_review_response_path(daily_response)

      # set_response scopes to current_user.daily_responses -> RecordNotFound,
      # which test env's show_exceptions = :rescuable renders as a 404.
      expect(response).to have_http_status(:not_found)
    end

    it "redirects with an alert when there is no review yet" do
      daily_response = create_reviewed_response(user, reviewed: false)

      expect {
        post email_review_response_path(daily_response)
      }.not_to have_enqueued_mail(ReviewMailer, :send_review)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("No review to email yet.")
    end

    it "enqueues the review email and confirms with the user's address" do
      daily_response = create_reviewed_response(user)

      expect {
        post email_review_response_path(daily_response)
      }.to have_enqueued_mail(ReviewMailer, :send_review).with(daily_response)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq("Review sent to dev@example.com.")
    end
  end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/requests/responses_spec.rb`
Expected: the 2 existing concept_tags examples still pass; the 4 new examples FAIL with `undefined method 'email_review_response_path'` (route doesn't exist yet).

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
Expected: 6 examples, 0 failures.

- [ ] **Step 6: Add the dashboard button**

In `app/views/dashboard/show.html.erb`, in the review-section block (as it stands after Task 1), replace the plain `h3` line with a heading row carrying the button — everything else, including the `feedback_form` renders below, stays untouched:

```erb
    <% if @response.reviewed? %>
      <div class="review-section">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.75rem">
          <h3 style="font-size:1rem">Claude's Review</h3>
          <%= button_to "Email me this review", email_review_response_path(@response), method: :post, class: "btn btn-ghost btn-sm" %>
        </div>
        <%= render "shared/ai_review", response: @response %>
      </div>
```

- [ ] **Step 7: Run dashboard + responses specs to verify nothing broke**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb spec/requests/responses_spec.rb`
Expected: 15 examples, 0 failures.

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
- Consumes: partial `shared/_ai_review` with `response:` local (Task 1); layout CSS `pre.snippet` / `.review-block` / `.review-rating` / `.review-item` (Task 1); `ApplicationController` auth before_actions; spec helpers `create_user_with_key` / `login_as`; `DailyResponse#concept_tags` (jsonb map of section → concept slug, default `{}` — real column, no `respond_to?` guard needed)
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
      problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
    )
  end

  describe "#answered_sections" do
    it "returns keys whose answers have substance (>10 chars), preserving the completeness heuristic" do
      daily_response = user.daily_responses.create!(
        daily_exercise: exercise,
        date: Date.current,
        answers: { "code_review" => "Found the N+1 in the loop", "pattern" => "short", "challenge" => "" }
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
  let(:user) { create_user_with_key }

  def create_session_for(owner, date:, submitted: true, reviewed: false, rating: nil, concept_tags: {})
    exercise = DailyExercise.create!(
      user: owner, date: date,
      problem_set: { "code_review" => { "question" => "q-#{date}", "snippet" => "s" } },
      generated_at: Time.current
    )
    DailyResponse.create!(
      user: owner, daily_exercise: exercise, date: date,
      answers: { "code_review" => "Answer with plenty of substance" },
      submitted_at: submitted ? Time.current : nil,
      rating: rating,
      concept_tags: concept_tags,
      ai_review: reviewed ? { "code_review" => { "rating" => "solid", "correct" => "Spotted the issue on #{date}" } } : nil
    )
  end

  describe "GET /history" do
    it "requires login" do
      get history_path
      expect(response).to redirect_to(login_path)
    end

    it "lists only the current user's submitted responses, newest first" do
      other = create_user_with_key(email: "other@example.com", name: "Other")
      old   = create_session_for(user, date: 3.days.ago.to_date, reviewed: true, rating: :too_hard)
      newer = create_session_for(user, date: 1.day.ago.to_date)
      create_session_for(user, date: Date.current, submitted: false)   # draft — excluded
      create_session_for(other, date: 2.days.ago.to_date)              # other user — excluded

      login_as(user)
      get history_path

      expect(response.body).to include(newer.date.strftime("%A, %B %-d, %Y"))
      expect(response.body).to include(old.date.strftime("%A, %B %-d, %Y"))
      expect(response.body).not_to include(Date.current.strftime("%A, %B %-d, %Y"))
      expect(response.body).not_to include(2.days.ago.to_date.strftime("%A, %B %-d, %Y"))
      expect(response.body.index(newer.date.strftime("%A, %B %-d, %Y")))
        .to be < response.body.index(old.date.strftime("%A, %B %-d, %Y"))
    end

    it "shows rating, concept tags, review content for reviewed entries, and a fallback otherwise" do
      create_session_for(user, date: 3.days.ago.to_date, reviewed: true, rating: :too_hard,
                         concept_tags: { "code_review" => "n_plus_one" })
      create_session_for(user, date: 1.day.ago.to_date)

      login_as(user)
      get history_path

      expect(response.body).to include("Too hard")
      expect(response.body).to include("N plus one")
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

Create `app/views/history/index.html.erb`:

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
      <% daily_response.concept_tags.values.compact.uniq.each do |tag| %>
        <span class="history-tag"><%= tag.humanize %></span>
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
Expected: 0 failures across all specs (models, requests, mailers, services).

- [ ] **Step 13: Commit**

```bash
git add app/models/daily_response.rb app/controllers/history_controller.rb app/views/history/index.html.erb config/routes.rb app/views/layouts/application.html.erb spec/models/daily_response_spec.rb spec/requests/history_spec.rb
git commit -m "Add /history page listing past submitted sessions

Newest first, submitted-only (drafts stay on the dashboard). Reuses
shared/_ai_review with reviews collapsed behind <details> (newest
open), and shows concept tags per entry. No pagination yet — ~22
entries/month; revisit with Pagy when volume warrants.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Verification (after all tasks)

- `bundle exec rspec` — full suite green.
- Manual smoke via `bin/dev` if desired: submit today's answers, request a review, click "Email me this review" (letter_opener shows the text email in dev), visit `/history` from the nav link.
