# Exercise-generation visual feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the dashboard live visual feedback during exercise generation (initial/on-demand, via Turbo Stream broadcast) and during regenerate (synchronous, via a spinner), and stop on-demand generation from auto-firing on weekends.

**Architecture:** Wire up ActionCable (already has `solid_cable` in the `Gemfile`/schema, but not mounted) so `GenerateDailyExercisesJob` can broadcast a Turbo Stream replacement of the dashboard's content on both success and failure. `DashboardController#show` gains a weekday guard so it only auto-enqueues on-demand generation Mon–Fri; a new `POST /generate` action lets the user manually trigger it on weekends. `regenerate` stays fully synchronous; a small Stimulus controller adds a disabled/spinner button state while that request is in flight.

**Tech Stack:** Rails 8.0.5, `turbo-rails` 2.0.23 (`Turbo::StreamsChannel`, `turbo_stream_from`), Stimulus (`@hotwired/stimulus`, importmap, `eagerLoadControllersFrom`), Solid Queue (jobs), Solid Cable (ActionCable pub/sub, Postgres-backed, already in `db/schema.rb`), RSpec (request/job specs, no Capybara/JS driver).

## Global Constraints

- No changes to magic-link auth, Resend/SMTP, `/test_login`, the feedback UI, the regenerate-button/multi-provider feature, or the email/history-page spec.
- Regenerate stays synchronous — do not convert it to a background job.
- No new retry endpoint — the error state's retry link reuses the existing dashboard `GET /` (`root_path`).
- No Redis, no new gems — broadcasting uses the already-present `turbo-rails` + `solid_cable`.
- No JS/system test tooling is being added — this app has no Capybara/JS driver; Stimulus behavior is verified manually in dev, not unit-tested.
- ActionCable connection auth reuses `request.session[:user_id]` (the same cookie session key `ApplicationController#current_user` already reads) — no new auth token scheme.

---

### Task 1: Wire up ActionCable

**Files:**
- Create: `app/channels/application_cable/connection.rb`
- Modify: `config/routes.rb`
- Modify: `config/environments/production.rb:64-65`
- Test: `spec/channels/application_cable/connection_spec.rb`

**Interfaces:**
- Consumes: `User.find_by(id:)` (existing), `request.session[:user_id]` (same key `ApplicationController#current_user` reads, per `app/controllers/application_controller.rb:9`).
- Produces: `ApplicationCable::Connection` with `identified_by :current_user`, used implicitly by `Turbo::StreamsChannel` (from the `turbo-rails` gem) in later tasks — no other class depends on this directly, but a connection must exist and successfully identify `current_user` for `turbo_stream_from` / `Turbo::StreamsChannel.broadcast_replace_to` to work at all.

- [ ] **Step 1: Write the failing connection spec**

Create `spec/channels/application_cable/connection_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:user) { create_user_with_key }

  it "identifies the connection's current_user from the session" do
    connect session: { user_id: user.id }
    expect(connection.current_user).to eq(user)
  end

  it "rejects the connection when there is no logged-in user in the session" do
    expect { connect session: {} }.to have_rejected_connection
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/channels/application_cable/connection_spec.rb`
Expected: FAIL — `uninitialized constant ApplicationCable` (the module/class doesn't exist yet).

- [ ] **Step 3: Create the connection class**

Create `app/channels/application_cable/connection.rb`:

```ruby
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      User.find_by(id: request.session[:user_id]) || reject_unauthorized_connection
    end
  end
end
```

- [ ] **Step 4: Mount ActionCable in routes**

In `config/routes.rb`, add the mount right after the healthcheck route:

```ruby
  # Railway healthcheck target (railway.toml healthcheckPath). Returns 200 once the
  # app has booted; served by Rails' built-in health controller, no auth required.
  get "up" => "rails/health#show", as: :rails_health_check

  # Turbo Stream broadcasts (exercise-generation live updates) ride over this.
  mount ActionCable.server => "/cable"

```

- [ ] **Step 5: Allow the app's own origin for WebSocket connections in production**

In `config/environments/production.rb`, right after the existing `app_host`/mailer block (around line 65), add:

```ruby
  app_host = URI.parse(ENV.fetch("APP_HOST", "https://example.com"))
  config.action_mailer.default_url_options = { host: app_host.host, protocol: "https" }

  # Allow the app's own origin to open ActionCable WebSocket connections
  # (Turbo Stream broadcasts for exercise-generation live updates). Reuses
  # the same APP_HOST env var as the mailer config above.
  config.action_cable.allowed_request_origins = [ app_host.host, "https://#{app_host.host}" ]
```

- [ ] **Step 6: Run the spec to verify it passes**

Run: `bundle exec rspec spec/channels/application_cable/connection_spec.rb`
Expected: PASS (2 examples, 0 failures)

- [ ] **Step 7: Commit**

```bash
git add app/channels/application_cable/connection.rb config/routes.rb config/environments/production.rb spec/channels/application_cable/connection_spec.rb
git commit -m "Wire up ActionCable for Turbo Stream broadcasts"
```

---

### Task 2: Extract dashboard partials and add the broadcast subscription

Pure restructuring — no behavior change. The three existing states are extracted into partials, wrapped in a `#dashboard-content` div, with a `turbo_stream_from current_user` subscription added. All existing `dashboard_spec.rb` examples must still pass unmodified, proving the refactor is behavior-preserving.

**Files:**
- Modify: `app/views/dashboard/show.html.erb` (currently 233 lines; see full content already read in this session)
- Create: `app/views/dashboard/_generating.html.erb`
- Create: `app/views/dashboard/_exercise.html.erb`
- Test: `spec/requests/dashboard_spec.rb` (no new examples in this task — existing ones must keep passing)

**Interfaces:**
- Consumes: `@exercise`, `@response`, `@generating` (all existing controller ivars, unchanged in this task), `current_user` (from `ApplicationController`).
- Produces: `dashboard/_generating` partial (no locals). `dashboard/_exercise` partial, locals `exercise:` (a `DailyExercise`) and `response:` (a `DailyResponse`, may be a new unpersisted record) — later tasks (3 and 4) render this same partial with the same two locals from the controller and from the background job respectively, so the local names `exercise:` and `response:` must stay exactly as defined here.
- The `#dashboard-content` div id and the `turbo_stream_from current_user` subscription are the two names Task 4's job broadcasts must match exactly (`target: "dashboard-content"`, broadcasting `to: user`).

- [ ] **Step 1: Extract the "generating" state into its own partial**

Create `app/views/dashboard/_generating.html.erb`:

```erb
<div class="section" style="text-align:center;padding:3rem;">
  <p style="color:var(--muted);margin-bottom:.5rem;">Generating your personalized exercise set…</p>
  <p style="font-size:.85rem;color:var(--muted);">This usually takes about 10 seconds — this page will update automatically.</p>
</div>
```

(This drops the old "Refresh in a moment" copy since the page now updates itself via broadcast — see Task 4.)

- [ ] **Step 2: Extract the exercise-content state into its own partial**

Create `app/views/dashboard/_exercise.html.erb` with the content that is currently the `<% else %>` branch of `show.html.erb` (lines 68–231), with `@exercise` replaced by the `exercise` local and `@response` replaced by the `response` local throughout:

```erb
<% submitted = response.persisted? && response.submitted? %>

<div class="regenerate-row" style="margin-bottom:1.5rem;">
  <% if exercise.regenerated_at.present? %>
    <p class="hint">You've already generated a new set today.</p>
  <% else %>
    <% has_progress = response.persisted? && (response.submitted? || response.answers.values.any?(&:present?)) %>
    <% confirm_msg = has_progress ?
         "This will replace today's problems and erase your answers so far. This can't be undone. Continue?" :
         "Generate a new set for today?" %>
    <%= button_to "Generate new set", regenerate_path, method: :post,
          class: "btn btn-ghost btn-sm", data: { turbo_confirm: confirm_msg } %>
  <% end %>
</div>

<%# Progress bar (only shown before submission; sticky so progress stays
    visible while scrolling the three sections on small screens) %>
<% unless submitted %>
  <div class="progress-sticky">
    <div class="progress-bar">
      <div class="progress-fill" id="progress-fill" style="width:0%"></div>
    </div>
    <div class="progress-label" id="progress-label">0 of 3 answered</div>
  </div>
<% end %>

<%# Always a real POST — ResponsesController#create is idempotent via
    find_or_initialize_by, so resumed/persisted drafts save the same way.
    There is no PATCH /responses route; spoofing one here 404s the form. %>
<%= form_with url: responses_path, method: :post, id: "gym-form", data: { turbo: false } do |f| %>
  <%# ── Section 1: Code Review ─────────────────────────────────────── %>
  <% cr = exercise.code_review %>
  <div class="section">
    <div class="section-label">1 — Code Review</div>
    <div class="question"><%= cr["question"] %></div>
    <pre class="snippet"><code><%= cr["snippet"] %></code></pre>

    <%= render "dashboard/teaching_hint", note: cr["teaching_note"], field: "code_review", submitted: submitted, answer: response.answers["code_review"] %>

    <% if submitted %>
      <div class="answer-display"><%= response.answers["code_review"].presence || "(skipped)" %></div>
    <% else %>
      <textarea name="response[answers][code_review]" class="answer" placeholder="What's the issue and how would you fix it?" data-field="code_review"><%= response.answers["code_review"] %></textarea>
    <% end %>
  </div>

  <%# ── Section 2: Pattern of the Month ─────────────────────────────── %>
  <% pat = exercise.pattern %>
  <div class="section">
    <div class="section-label">2 — Pattern of the Month: <%= pat["title"] %></div>
    <div class="why-box"><strong>Why it exists:</strong> <%= pat["why"] %></div>
    <div class="question"><%= pat["question"] %></div>

    <details class="ref">
      <summary>Reference — <%= pat["title"] %>: how it works</summary>
      <div class="ref-body">
        <p style="margin-bottom:.75rem"><strong><%= pat.dig("reference", "tagline") %></strong></p>
        <p style="margin-bottom:.75rem"><%= pat.dig("reference", "explanation") %></p>
        <pre class="snippet"><code><%= pat.dig("reference", "code_example") %></code></pre>
        <p>🔭 <%= pat.dig("reference", "senior_lens") %></p>
      </div>
    </details>

    <%= render "dashboard/teaching_hint", note: pat["teaching_note"], field: "pattern", submitted: submitted, answer: response.answers["pattern"] %>

    <% if submitted %>
      <div class="answer-display"><%= response.answers["pattern"].presence || "(skipped)" %></div>
    <% else %>
      <textarea name="response[answers][pattern]" class="answer" placeholder="Your answer…" data-field="pattern"><%= response.answers["pattern"] %></textarea>
    <% end %>
  </div>

  <%# ── Section 3: Coding Challenge ─────────────────────────────────── %>
  <% ch = exercise.challenge %>
  <div class="section">
    <div class="section-label">3 — Coding Challenge</div>
    <div class="question"><%= ch["question"] %></div>
    <% if ch["starter_code"].present? %>
      <pre class="snippet"><code><%= ch["starter_code"] %></code></pre>
    <% end %>

    <%= render "dashboard/teaching_hint", note: ch["teaching_note"], field: "challenge", submitted: submitted, answer: response.answers["challenge"] %>

    <% if submitted %>
      <div class="answer-display"><%= response.answers["challenge"].presence || "(skipped)" %></div>
    <% else %>
      <textarea name="response[answers][challenge]" class="answer code-answer" placeholder="# Your implementation…" data-field="challenge"><%= response.answers["challenge"] %></textarea>
    <% end %>
  </div>

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
    <% unless response.reviewed? %>
      <%= button_to "Get Claude review →", review_response_path(response), method: :post, class: "btn btn-primary btn-sm" %>
    <% end %>
  </div>

  <% if response.reviewed? %>
    <div class="review-section">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.75rem">
        <h3 style="font-size:1rem">Claude's Review</h3>
        <%= button_to "Email me this review", email_review_response_path(response), method: :post, class: "btn btn-ghost btn-sm" %>
      </div>
      <%= render "shared/ai_review", response: response %>
    </div>
    <%= render "responses/feedback_form", response: response, style: :prominent %>
  <% else %>
    <%= render "responses/feedback_form", response: response, style: :quiet %>
  <% end %>
<% end %>

<%# Auto-save script %>
<% unless submitted %>
  <script>
    const form = document.getElementById("gym-form");
    const textareas = form.querySelectorAll("textarea[data-field]");
    const progressFill = document.getElementById("progress-fill");
    const progressLabel = document.getElementById("progress-label");

    function updateProgress() {
      const filled = [...textareas].filter(t => t.value.trim().length > 10).length;
      progressFill.style.width = (filled / 3 * 100) + "%";
      progressLabel.textContent = filled === 3 ? "✓ All answered — ready to submit!" : `${filled} of 3 answered`;
      document.querySelectorAll("details.hint[data-hint-for]").forEach(d => {
        const t = form.querySelector(`textarea[data-field="${d.dataset.hintFor}"]`);
        if (t) d.classList.toggle("locked", t.value.trim().length <= 10);
      });
    }

    let saveTimer;
    function autoSave() {
      clearTimeout(saveTimer);
      saveTimer = setTimeout(async () => {
        const answers = {};
        textareas.forEach(t => answers[t.dataset.field] = t.value);
        await fetch(form.action, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content },
          body: JSON.stringify({ response: { answers } })
        });
      }, 800);
    }

    textareas.forEach(t => {
      t.addEventListener("input", () => { updateProgress(); autoSave(); });
    });

    updateProgress();
  </script>
<% end %>
```

- [ ] **Step 3: Replace `show.html.erb`'s body with the dispatcher + broadcast wrapper**

Replace lines 57–232 of `app/views/dashboard/show.html.erb` (the `<% if @generating %>` ... final `<% end %>`) with:

```erb
<%= turbo_stream_from current_user %>

<div id="dashboard-content">
  <% if @generating %>
    <%= render "dashboard/generating" %>
  <% elsif @exercise.nil? %>
    <%= render "dashboard/generating" %>
  <% else %>
    <%= render "dashboard/exercise", exercise: @exercise, response: @response %>
  <% end %>
</div>
```

(The `@exercise.nil?` fallback branch is temporary — Task 3 replaces it with the weekend-specific state. Keeping it here for now means this task's diff is a pure, behavior-preserving refactor: every branch that could render before still renders the same partial now.)

- [ ] **Step 4: Run the full existing dashboard spec suite to verify no regressions**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: PASS — all existing examples (feedback widgets, form method, regenerate button states, teaching hints) still pass unchanged, since the rendered HTML is identical.

- [ ] **Step 5: Commit**

```bash
git add app/views/dashboard/show.html.erb app/views/dashboard/_generating.html.erb app/views/dashboard/_exercise.html.erb
git commit -m "Extract dashboard states into partials; add Turbo Stream subscription"
```

---

### Task 3: Weekday guard + manual weekend generate action

**Files:**
- Modify: `app/controllers/dashboard_controller.rb`
- Modify: `app/controllers/daily_exercises_controller.rb`
- Modify: `config/routes.rb`
- Create: `app/views/dashboard/_weekend_empty.html.erb`
- Modify: `app/views/dashboard/show.html.erb` (replace the temporary `@exercise.nil?` fallback branch from Task 2)
- Test: `spec/requests/dashboard_spec.rb`
- Test: `spec/requests/daily_exercises_spec.rb`

**Interfaces:**
- Consumes: `dashboard/_exercise` and `dashboard/_generating` partials (Task 2), `#dashboard-content` div (Task 2), `GenerateDailyExercisesJob.perform_later(user_id:)` (existing).
- Produces: `POST /generate` route → `DailyExercisesController#generate`. `@weekend_no_exercise` controller ivar, read by `show.html.erb`.

- [ ] **Step 1: Write failing specs for the weekday guard**

Add to `spec/requests/dashboard_spec.rb` (new `describe` block, needs `travel_to`, already available via `ActiveSupport::Testing::TimeHelpers` per `spec/rails_helper.rb`, and `ActiveJob::TestHelper` for `have_enqueued_job`):

```ruby
require "rails_helper"

RSpec.describe "Dashboard feedback and review display", type: :request do
  include ActiveJob::TestHelper
  # ... (existing let/def/before unchanged)
```

Then add this new `describe` block at the end of the file, right before the final `end`:

```ruby
  describe "on-demand generation and the weekday guard" do
    around do |example|
      # A known Monday and a known Saturday, so weekday?/weekend? are unambiguous
      # regardless of when the suite runs.
      travel_to(anchor_date) { example.run }
    end

    context "on a weekday" do
      let(:anchor_date) { Date.new(2026, 7, 13) } # Monday

      it "auto-enqueues generation and shows the generating state" do
        expect {
          get root_path
        }.to have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id)

        expect(response.body).to include("Generating your personalized exercise set")
      end
    end

    context "on a weekend" do
      let(:anchor_date) { Date.new(2026, 7, 18) } # Saturday

      it "does not auto-enqueue generation and shows the weekend message instead" do
        expect {
          get root_path
        }.not_to have_enqueued_job(GenerateDailyExercisesJob)

        expect(response.body).to include("No exercises are generated automatically on weekends")
        expect(response.body).to include("Generate today's set anyway")
      end
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "on-demand generation and the weekday guard"`
Expected: FAIL on the weekend example — the job is still enqueued and the weekend copy doesn't exist yet (current controller has no weekday check).

- [ ] **Step 3: Add the weekday guard to `DashboardController#show`**

Replace the whole `DashboardController` in `app/controllers/dashboard_controller.rb`:

```ruby
class DashboardController < ApplicationController
  def show
    @exercise = current_user.daily_exercises.for_date.first
    @response = @exercise&.daily_response ||
                @exercise && DailyResponse.new(user: current_user, daily_exercise: @exercise, date: Date.current)

    return unless @exercise.nil? && current_user.api_key_present?

    if flash[:generating]
      # Set by DailyExercisesController#generate right after a manual weekend
      # trigger — avoids re-enqueueing a second job on this same request.
      @generating = true
    elsif Date.current.on_weekday?
      GenerateDailyExercisesJob.perform_later(user_id: current_user.id)
      @generating = true
    else
      @weekend_no_exercise = true
    end
  end
end
```

- [ ] **Step 4: Add the `_weekend_empty` partial**

Create `app/views/dashboard/_weekend_empty.html.erb`:

```erb
<div class="section" style="text-align:center;padding:3rem;">
  <p style="color:var(--muted);margin-bottom:1rem;">No exercises are generated automatically on weekends — the morning job runs Monday–Friday.</p>
  <%= button_to "Generate today's set anyway", generate_path, method: :post, class: "btn btn-ghost btn-sm" %>
</div>
```

- [ ] **Step 5: Update `show.html.erb` to render the weekend state**

In `app/views/dashboard/show.html.erb`, replace the temporary fallback from Task 2:

```erb
  <% elsif @exercise.nil? %>
    <%= render "dashboard/generating" %>
```

with:

```erb
  <% elsif @weekend_no_exercise %>
    <%= render "dashboard/weekend_empty" %>
```

- [ ] **Step 6: Add the route and controller action for the manual weekend trigger**

In `config/routes.rb`, right after the existing `regenerate` route:

```ruby
  # Manually re-run today's exercise generation (capped at once/day in the controller)
  post "regenerate", to: "daily_exercises#regenerate"

  # Manually trigger on-demand generation when the automatic weekday trigger
  # in DashboardController#show intentionally didn't fire (weekends).
  post "generate", to: "daily_exercises#generate"
```

In `app/controllers/daily_exercises_controller.rb`, add the new action:

```ruby
class DailyExercisesController < ApplicationController
  # POST /generate — manually trigger on-demand generation for today, for the
  # case where DashboardController#show's automatic weekday trigger didn't
  # fire (weekends). No-ops (just redirects) if today's exercise already
  # exists, so a duplicate click can't enqueue a second generation.
  def generate
    return redirect_to root_path if current_user.daily_exercises.for_date.exists?

    GenerateDailyExercisesJob.perform_later(user_id: current_user.id)
    redirect_to root_path, flash: { generating: true }
  end

  # POST /regenerate — manually re-run today's exercise generation, capped
  # at once per day via regenerated_at. Replaces the existing DailyExercise
  # row's contents in place; never creates a second row for the same day.
  def regenerate
    exercise = current_user.daily_exercises.for_date.first
    return redirect_to root_path, alert: "No exercise set to regenerate yet." unless exercise

    if exercise.regenerated_at.present?
      return redirect_to root_path, alert: "You've already generated a new set today."
    end

    problem_set = AiService.for(current_user).generate_exercise(current_user, language: exercise.language)

    ActiveRecord::Base.transaction do
      exercise.daily_response&.destroy
      exercise.update!(
        problem_set:    problem_set,
        generated_at:   Time.current,
        regenerated_at: Time.current
      )
    end

    redirect_to root_path, notice: "New set generated!"
  rescue AiService::Error => e
    redirect_to root_path, alert: "Couldn't generate a new set: #{e.message}"
  end
end
```

- [ ] **Step 7: Run the dashboard specs to verify they pass**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: PASS — all examples, including the two new weekday-guard ones.

- [ ] **Step 8: Write and run a failing spec for `POST /generate`**

Add to `spec/requests/daily_exercises_spec.rb`, a new `describe` block before the final `end`:

```ruby
  describe "POST /generate" do
    include ActiveJob::TestHelper

    it "enqueues generation and redirects with the generating flash when there's no exercise yet" do
      expect {
        post generate_path
      }.to have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id)

      expect(response).to redirect_to(root_path)
      expect(flash[:generating]).to be true
    end

    it "no-ops if today's exercise already exists" do
      create_exercise

      expect {
        post generate_path
      }.not_to have_enqueued_job(GenerateDailyExercisesJob)

      expect(response).to redirect_to(root_path)
    end
  end
```

Run: `bundle exec rspec spec/requests/daily_exercises_spec.rb -e "POST /generate"`
Expected: FAIL — route/action don't exist until Step 6 above (if executed before Step 6; since Step 6 already ran, this should now PASS — run it anyway to confirm).

- [ ] **Step 9: Run it to verify it passes**

Run: `bundle exec rspec spec/requests/daily_exercises_spec.rb`
Expected: PASS — all examples, including the two new `POST /generate` ones.

- [ ] **Step 10: Commit**

```bash
git add app/controllers/dashboard_controller.rb app/controllers/daily_exercises_controller.rb config/routes.rb app/views/dashboard/show.html.erb app/views/dashboard/_weekend_empty.html.erb spec/requests/dashboard_spec.rb spec/requests/daily_exercises_spec.rb
git commit -m "Add weekday guard for on-demand generation, with manual weekend trigger"
```

---

### Task 4: Broadcast success/failure from the generation job

**Files:**
- Modify: `app/jobs/generate_daily_exercises_job.rb`
- Create: `app/views/dashboard/_generation_failed.html.erb`
- Test: `spec/jobs/generate_daily_exercises_job_spec.rb`

**Interfaces:**
- Consumes: `dashboard/_exercise` partial with `exercise:`/`response:` locals (Task 2), `#dashboard-content` broadcast target + `turbo_stream_from current_user` subscription (Task 2), `Turbo::StreamsChannel.broadcast_replace_to(streamable, target:, partial:, locals:)` (from `turbo-rails`, available once Task 1's ActionCable wiring is in place).
- Produces: broadcasts on the `user` stream with target `"dashboard-content"` — no other code depends on this directly; it's the terminal effect the browser subscription (Task 2) reacts to.

- [ ] **Step 1: Write failing job specs for the broadcasts**

Add to `spec/jobs/generate_daily_exercises_job_spec.rb`, two new examples (the file already has `let(:user)` and existing examples — add these after the existing ones, before the final `end`):

```ruby
  it "broadcasts the rendered exercise partial to the user's stream on success" do
    fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to) do |streamable, target:, partial:, locals:|
      expect(streamable).to eq(user)
      expect(target).to eq("dashboard-content")
      expect(partial).to eq("dashboard/exercise")
      expect(locals[:exercise]).to be_a(DailyExercise)
      expect(locals[:exercise].user).to eq(user)
      expect(locals[:response]).to be_a(DailyResponse)
      expect(locals[:response]).not_to be_persisted
    end

    described_class.new.perform(user_id: user.id)
  end

  it "broadcasts a friendly failure partial to the user's stream when AiService::Error is raised" do
    fake_service = instance_double(ClaudeService)
    allow(fake_service).to receive(:generate_exercise).and_raise(AiService::Error, "boom")
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    allow(Rails.logger).to receive(:error)

    expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
      .with(user, target: "dashboard-content", partial: "dashboard/generation_failed", locals: { message: "boom" })

    described_class.new.perform(user_id: user.id)
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/jobs/generate_daily_exercises_job_spec.rb -e "broadcasts"`
Expected: FAIL — `Turbo::StreamsChannel.broadcast_replace_to` is never called (job doesn't broadcast yet).

- [ ] **Step 3: Add the broadcasts to the job**

Replace `generate_for` in `app/jobs/generate_daily_exercises_job.rb`:

```ruby
  def generate_for(user)
    language    = user.language_for_today
    problem_set = AiService.for(user).generate_exercise(user, language: language)

    exercise = DailyExercise.create!(
      user:         user,
      date:         Date.current,
      problem_set:  problem_set,
      generated_at: Time.current,
      language:     language
    )

    Turbo::StreamsChannel.broadcast_replace_to(
      user,
      target:  "dashboard-content",
      partial: "dashboard/exercise",
      locals:  { exercise: exercise, response: DailyResponse.new(user: user, daily_exercise: exercise, date: Date.current) }
    )

    Rails.logger.info("Generated exercise for #{user.email} on #{Date.current}")
  rescue AiService::Error => e
    Rails.logger.error("Failed to generate exercise for #{user.email}: #{e.message}")
    Turbo::StreamsChannel.broadcast_replace_to(
      user,
      target:  "dashboard-content",
      partial: "dashboard/generation_failed",
      locals:  { message: e.message }
    )
    # Don't re-raise — one failure shouldn't block other users in the batch
  rescue ActiveRecord::RecordNotUnique
    # Lost a race against a concurrent generation for this user/date (e.g. two
    # dashboard loads both finding no exercise before either could create
    # one). The other one won; nothing to do here.
    Rails.logger.info("Skipped duplicate generation for #{user.email} on #{Date.current} (already generated concurrently)")
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors[:date].present?
    Rails.logger.info("Skipped duplicate generation for #{user.email} on #{Date.current} (already generated concurrently)")
  end
```

- [ ] **Step 4: Add the `_generation_failed` partial**

Create `app/views/dashboard/_generation_failed.html.erb`:

```erb
<div class="section" style="text-align:center;padding:3rem;">
  <p style="color:var(--muted);margin-bottom:.5rem;">Couldn't generate today's exercises.</p>
  <p style="font-size:.85rem;color:var(--muted);margin-bottom:1rem;"><%= message %></p>
  <a href="<%= root_path %>" class="btn btn-ghost btn-sm">Try again</a>
</div>
```

- [ ] **Step 5: Run the job specs to verify they pass**

Run: `bundle exec rspec spec/jobs/generate_daily_exercises_job_spec.rb`
Expected: PASS — all examples, including the two new broadcast ones.

- [ ] **Step 6: Run the dashboard and daily_exercises specs too, to confirm no regressions**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb spec/requests/daily_exercises_spec.rb`
Expected: PASS — unaffected by this task's job-only changes.

- [ ] **Step 7: Commit**

```bash
git add app/jobs/generate_daily_exercises_job.rb app/views/dashboard/_generation_failed.html.erb spec/jobs/generate_daily_exercises_job_spec.rb
git commit -m "Broadcast exercise-generation success/failure via Turbo Streams"
```

---

### Task 5: Regenerate button spinner (Stimulus)

**Files:**
- Create: `app/javascript/controllers/regenerate_controller.js`
- Modify: `app/views/dashboard/_exercise.html.erb`

**Interfaces:**
- Consumes: Turbo's `turbo:submit-start` / `turbo:submit-end` events (dispatched on the `<form>` element `button_to` generates), Stimulus `Controller` base class, `eagerLoadControllersFrom("controllers", application)` (existing, in `app/javascript/controllers/index.js` — auto-registers any `*_controller.js` file in this directory, no manual registration needed).
- Produces: a `regenerate` Stimulus identifier, referenced by `data-controller="regenerate"` / `data-action="turbo:submit-start->regenerate#start turbo:submit-end->regenerate#stop"` / `data-regenerate-target="button"` in `_exercise.html.erb`. No other file depends on this.

This app has no JS/system test tooling (no Capybara/JS driver), so this task is verified manually in `bin/dev`, not via an automated spec — consistent with the plan's Global Constraints.

- [ ] **Step 1: Create the Stimulus controller**

Create `app/javascript/controllers/regenerate_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// Attached to the "Generate new set" button_to form. regenerate stays a
// fully synchronous POST (see docs/superpowers/specs/2026-07-12-visual-feedback-design.md),
// so this only gives the ~10s wait a disabled/spinner button state instead
// of silence.
export default class extends Controller {
  static targets = ["button"]

  connect() {
    this.originalLabel = this.buttonTarget.textContent
  }

  start() {
    this.buttonTarget.disabled = true
    this.buttonTarget.textContent = "Generating…"
  }

  stop() {
    this.buttonTarget.disabled = false
    this.buttonTarget.textContent = this.originalLabel
  }
}
```

- [ ] **Step 2: Wire the controller onto the regenerate button in `_exercise.html.erb`**

In `app/views/dashboard/_exercise.html.erb`, replace:

```erb
    <%= button_to "Generate new set", regenerate_path, method: :post,
          class: "btn btn-ghost btn-sm", data: { turbo_confirm: confirm_msg } %>
```

with:

```erb
    <%= button_to "Generate new set", regenerate_path, method: :post,
          class: "btn btn-ghost btn-sm",
          data: { turbo_confirm: confirm_msg, regenerate_target: "button" },
          form: { data: { controller: "regenerate",
                          action: "turbo:submit-start->regenerate#start turbo:submit-end->regenerate#stop" } } %>
```

- [ ] **Step 3: Verify manually in dev**

Run: `bin/dev` (starts web + Solid Queue worker), then in a browser: log in, load the dashboard with an existing exercise, click "Generate new set", confirm the dialog. Expected: the button immediately becomes disabled and reads "Generating…" for the duration of the request, then the page redirects/reloads with the new set (button reverts naturally since it's a fresh page load).

- [ ] **Step 4: Run the full dashboard/daily_exercises specs to confirm the markup change doesn't break existing assertions**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb spec/requests/daily_exercises_spec.rb`
Expected: PASS — the existing specs check for button text/confirm copy, which is unchanged; only `data-controller`/`data-action`/`data-regenerate-target` attributes were added.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/controllers/regenerate_controller.js app/views/dashboard/_exercise.html.erb
git commit -m "Add spinner/disabled state to the regenerate button"
```

---

## Final verification

- [ ] Run the full test suite: `bundle exec rspec`
- Expected: all examples pass, no regressions in any other spec file.
