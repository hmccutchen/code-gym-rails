# Async Regenerate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `DailyExercisesController#regenerate` off the request thread so it enqueues a background job instead of blocking on the AI provider.

**Architecture:** Add a `regenerating_since` claim column to `daily_exercises`, mirroring the existing `daily_responses.reviewing_since` pattern. The controller claims the row with a single atomic `UPDATE` and enqueues `RegenerateExerciseJob`; the job replaces the problem set in place on the worker. The dashboard reuses its existing spinner partial and `/dashboard/status` poller, which gain a "regenerating" state.

**Tech Stack:** Rails 8.0.5, PostgreSQL, Solid Queue, RSpec.

Spec: `docs/superpowers/specs/2026-08-07-async-regenerate-design.md`

## Global Constraints

- All work happens on the `async-regenerate` branch, never on `main`.
- Run the suite with `bundle exec rspec`; lint with `bundle exec rubocop`.
- Code is self-documenting. Only add a comment to explain a non-obvious *why* — never to restate *what* the code does.
- Background jobs that call an AI provider must log and move on. No provider failure may surface as a user-facing crash.
- Anything resolving "today" for a user must run inside `Time.use_zone(user.effective_time_zone)`.
- `ActiveJob` uses the `:test` adapter in specs (`config/environments/test.rb:44`), so enqueued jobs do not run inline — assert with `have_enqueued_job`.
- Test helpers: `create_user_with_key`, `login_as(user)` (`spec/support/auth_helpers.rb`).
- **Deviation from spec, applied deliberately:** the spec placed `REGENERATION_STALE_AFTER` on `DailyExercisesController`. This plan puts it on `DailyExercise` alongside a `regenerating?` predicate, because `DashboardController` (show *and* status) and a view all need the freshness check, and a cross-controller constant reference would be worse. This matches the repo's `reviewed?`/`submitted?` predicate convention.

---

### Task 1: Claim column and staleness predicate

**Files:**
- Create: `db/migrate/20260807000001_add_regenerating_since_to_daily_exercises.rb`
- Modify: `app/models/daily_exercise.rb`
- Test: `spec/models/daily_exercise_spec.rb`

**Interfaces:**
- Produces: `DailyExercise::REGENERATION_STALE_AFTER` (`ActiveSupport::Duration`), `DailyExercise#regenerating?` → `Boolean`, and the `daily_exercises.regenerating_since` `datetime` column (nullable).

- [ ] **Step 1: Write the failing tests**

Append inside the top-level `RSpec.describe DailyExercise do` block in `spec/models/daily_exercise_spec.rb`:

```ruby
  describe "#regenerating?" do
    let(:user) { User.create!(email: "regen-model@example.com", name: "Regen") }

    def exercise(regenerating_since: nil)
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                            problem_set: { "code_review" => { "question" => "q" } },
                            regenerating_since: regenerating_since)
    end

    it "is false when no regeneration has been claimed" do
      expect(exercise).not_to be_regenerating
    end

    it "is true while a fresh claim is held" do
      expect(exercise(regenerating_since: 10.seconds.ago)).to be_regenerating
    end

    # A worker that dies mid-job would otherwise leave the claim set forever and
    # strand the user on a spinner, so the claim expires rather than latching.
    it "is false once the claim is older than the stale window" do
      stale = DailyExercise::REGENERATION_STALE_AFTER.ago - 1.second
      expect(exercise(regenerating_since: stale)).not_to be_regenerating
    end

    # A claim must outlive the longest generation the worker can legitimately
    # run, or a still-running job looks abandoned and a second one piles on.
    it "outlasts the worker's generation budget" do
      expect(DailyExercise::REGENERATION_STALE_AFTER.to_i).to be > AiService::GENERATION_READ_TIMEOUT
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/models/daily_exercise_spec.rb -e "#regenerating?"`
Expected: FAIL — `unknown attribute 'regenerating_since'` and `uninitialized constant DailyExercise::REGENERATION_STALE_AFTER`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260807000001_add_regenerating_since_to_daily_exercises.rb`:

```ruby
class AddRegeneratingSinceToDailyExercises < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_exercises, :regenerating_since, :datetime
  end
end
```

- [ ] **Step 4: Run the migration**

Run: `bundle exec rails db:migrate && RAILS_ENV=test bundle exec rails db:migrate`
Expected: `db/schema.rb` now lists `t.datetime "regenerating_since"` on `daily_exercises`.

- [ ] **Step 5: Add the constant and predicate**

In `app/models/daily_exercise.rb`, add near the existing `scope :for_date`:

```ruby
  # A regeneration claim expires so a worker that dies mid-job can't strand the
  # user on a spinner forever. Must exceed AiService::GENERATION_READ_TIMEOUT
  # plus job pickup, or a healthy long-running job looks abandoned.
  REGENERATION_STALE_AFTER = 6.minutes

  def regenerating?
    regenerating_since.present? && regenerating_since > REGENERATION_STALE_AFTER.ago
  end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bundle exec rspec spec/models/daily_exercise_spec.rb`
Expected: PASS, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/daily_exercise.rb spec/models/daily_exercise_spec.rb
git commit -m "Add an expiring regeneration claim to DailyExercise"
```

---

### Task 2: RegenerateExerciseJob

**Files:**
- Create: `app/jobs/regenerate_exercise_job.rb`
- Test: `spec/jobs/regenerate_exercise_job_spec.rb`

**Interfaces:**
- Consumes: `DailyExercise#regenerating?`, `regenerating_since` (Task 1).
- Produces: `RegenerateExerciseJob.perform_later(user_id: Integer)`. On success sets `problem_set`, `generated_at`, `regenerated_at` and clears `regenerating_since`. On failure clears only `regenerating_since` and writes `user.last_generation_error{,_date}`.

- [ ] **Step 1: Write the failing tests**

Create `spec/jobs/regenerate_exercise_job_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe RegenerateExerciseJob do
  let(:user) { create_user_with_key(email: "regen-job@example.com") }

  def claimed_exercise
    DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago,
                          language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "old" } },
                          regenerating_since: Time.current)
  end

  def stub_provider(result)
    fake_service = instance_double(ClaudeService)
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    if result.is_a?(StandardError)
      allow(fake_service).to receive(:generate_exercise).and_raise(result)
    else
      allow(fake_service).to receive(:generate_exercise).and_return(result)
    end
    fake_service
  end

  it "replaces the problem set in place and releases the claim" do
    exercise = claimed_exercise
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    exercise.reload
    expect(exercise.problem_set).to eq("code_review" => { "question" => "new" })
    expect(exercise.regenerated_at).to be_present
    expect(exercise.regenerating_since).to be_nil
  end

  it "destroys the existing response so the new set starts clean" do
    exercise = claimed_exercise
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "a" * 20 })
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(exercise.reload.daily_response).to be_nil
  end

  it "regenerates in the exercise's own stored language" do
    exercise = claimed_exercise
    exercise.update!(language: "javascript")
    fake_service = stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(fake_service).to have_received(:generate_exercise).with(user, language: "javascript")
  end

  # The whole point of regenerating in place: a provider failure must not cost
  # the user the set they already have, nor their one regenerate for the day.
  it "preserves the existing set and the daily allowance when the provider fails" do
    exercise = claimed_exercise
    stub_provider(AiService::Error.new("boom"))

    described_class.new.perform(user_id: user.id)

    exercise.reload
    expect(exercise.problem_set).to eq("code_review" => { "question" => "old" })
    expect(exercise.regenerated_at).to be_nil
    expect(exercise.regenerating_since).to be_nil
    expect(user.reload.last_generation_error).to eq("boom")
    expect(user.last_generation_error_date).to eq(Date.current)
  end

  it "does not raise when the provider fails" do
    claimed_exercise
    stub_provider(AiService::Error.new("boom"))

    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
  end

  it "reports a rejected key in the user's language, not the provider's" do
    claimed_exercise
    stub_provider(AiService::AuthenticationError.new("401 invalid x-api-key"))

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error).to eq("Your API key was rejected — check it in Settings.")
    expect(user.last_generation_error).not_to include("x-api-key")
  end

  it "reports rate limiting as a try-again, not a configuration problem" do
    claimed_exercise
    stub_provider(AiService::RateLimitError.new("rate limited"))

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error)
      .to eq("The AI provider is rate-limiting requests — try again shortly.")
  end

  it "preserves the existing response when the provider fails" do
    exercise = claimed_exercise
    daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                           answers: { "code_review" => "important work" })
    stub_provider(AiService::Error.new("timeout"))

    described_class.new.perform(user_id: user.id)

    expect(DailyResponse.exists?(daily_response.id)).to be(true)
    expect(daily_response.reload.answers).to eq("code_review" => "important work")
  end

  # A nil problem_set fails DailyExercise's presence validation, so exercise.update!
  # raises inside the transaction after the response has already been destroyed.
  # Without the transaction the user would lose their answers to a bad payload.
  it "rolls back the destroyed response when the replacement set is invalid" do
    exercise = claimed_exercise
    daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                           answers: { "code_review" => "important work" })
    stub_provider(nil)

    described_class.new.perform(user_id: user.id)

    expect(DailyResponse.exists?(daily_response.id)).to be(true)
    expect(daily_response.reload.answers).to eq("code_review" => "important work")
    exercise.reload
    expect(exercise.regenerated_at).to be_nil
    expect(exercise.regenerating_since).to be_nil
    expect(exercise.problem_set).to eq("code_review" => { "question" => "old" })
    expect(user.reload.last_generation_error).to eq("Generation returned an unusable set — try again.")
  end

  it "clears a prior failure once regeneration succeeds" do
    user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
    claimed_exercise
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error).to be_nil
    expect(user.last_generation_error_date).to be_nil
  end

  # Without the claim there is nothing to finish, so a stray or duplicated job
  # must not spend a second provider call replacing a set nobody asked about.
  it "does nothing when no claim is held" do
    exercise = claimed_exercise
    exercise.update!(regenerating_since: nil)
    allow(AiService).to receive(:for)

    described_class.new.perform(user_id: user.id)

    expect(AiService).not_to have_received(:for)
    expect(exercise.reload.problem_set).to eq("code_review" => { "question" => "old" })
  end

  it "skips an anonymized user" do
    claimed_exercise
    user.anonymize!
    allow(AiService).to receive(:for)

    described_class.new.perform(user_id: user.id)

    expect(AiService).not_to have_received(:for)
  end

  # Date.current must mean the user's today, not the server's, or a user west of
  # UTC regenerates a row dated tomorrow.
  it "resolves today in the user's own time zone" do
    user.update!(time_zone: "Hawaii")
    travel_to Time.utc(2026, 8, 7, 5, 0, 0) do
      exercise = DailyExercise.create!(user: user, date: Date.new(2026, 8, 6),
                                       generated_at: 1.hour.ago,
                                       problem_set: { "code_review" => { "question" => "old" } },
                                       regenerating_since: Time.current)
      stub_provider({ "code_review" => { "question" => "new" } })

      described_class.new.perform(user_id: user.id)

      expect(exercise.reload.problem_set).to eq("code_review" => { "question" => "new" })
    end
  end
end
```

Add `include ActiveSupport::Testing::TimeHelpers` immediately after the `RSpec.describe` line so `travel_to` resolves:

```ruby
RSpec.describe RegenerateExerciseJob do
  include ActiveSupport::Testing::TimeHelpers
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/jobs/regenerate_exercise_job_spec.rb`
Expected: FAIL — `uninitialized constant RegenerateExerciseJob`.

- [ ] **Step 3: Write the job**

Create `app/jobs/regenerate_exercise_job.rb`:

```ruby
class RegenerateExerciseJob < ApplicationJob
  queue_as :default

  def perform(user_id:)
    user = User.active.find_by(id: user_id)
    return unless user

    Time.use_zone(user.effective_time_zone) { regenerate(user) }
  end

  private

  def regenerate(user)
    exercise = user.daily_exercises.for_date.first
    return unless exercise&.regenerating_since

    problem_set = AiService.for(user).generate_exercise(user, language: exercise.language)

    ActiveRecord::Base.transaction do
      exercise.daily_response&.destroy
      exercise.update!(
        problem_set:        problem_set,
        generated_at:       Time.current,
        regenerated_at:     Time.current,
        regenerating_since: nil
      )
    end

    user.update!(last_generation_error_date: nil, last_generation_error: nil) if user.last_generation_error_date.present?
    Rails.logger.info("Regenerated exercise for #{user.email} on #{Date.current}")
  rescue AiService::AuthenticationError => e
    release(user, exercise, "Your API key was rejected — check it in Settings.", e)
  rescue AiService::RateLimitError => e
    release(user, exercise, "The AI provider is rate-limiting requests — try again shortly.", e)
  rescue AiService::Error => e
    release(user, exercise, e.message, e)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    release(user, exercise, "Generation returned an unusable set — try again.", e)
  end

  # regenerated_at is deliberately left untouched: a failed attempt must not
  # consume the user's one regeneration for the day.
  def release(user, exercise, message, error)
    Rails.logger.error("Failed to regenerate exercise for #{user.email}: #{error.message}")
    exercise&.update_columns(regenerating_since: nil)
    user.update!(last_generation_error_date: Date.current, last_generation_error: message)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/jobs/regenerate_exercise_job_spec.rb`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/jobs/regenerate_exercise_job.rb spec/jobs/regenerate_exercise_job_spec.rb
git commit -m "Add RegenerateExerciseJob"
```

---

### Task 3: Claim and enqueue instead of blocking

**Files:**
- Modify: `app/controllers/daily_exercises_controller.rb:20-46`
- Test: `spec/requests/daily_exercises_spec.rb`

**Interfaces:**
- Consumes: `RegenerateExerciseJob` (Task 2), `DailyExercise::REGENERATION_STALE_AFTER` (Task 1).
- Produces: `POST /regenerate` performs no provider I/O; it sets `regenerating_since` and redirects to `root_path` with `flash[:generating]`.

- [ ] **Step 1: Replace the existing regenerate specs**

In `spec/requests/daily_exercises_spec.rb`, inside `describe "POST /regenerate"`, delete these seven examples — every one asserts inline provider behavior that now lives in `RegenerateExerciseJob`, and Task 2's job spec already covers each:

- `"replaces the problem_set, sets regenerated_at, and destroys the existing response"`
- `"regenerates using the exercise's own stored language, not the user's current mixed alternation"`
- `"redirects with an alert when the provider raises"`
- `"shows a Settings-pointing alert without leaking the provider message when the provider raises AuthenticationError"`
- `"shows a try-again alert when the provider raises RateLimitError"`
- `"preserves the existing DailyResponse when the AI call fails"`
- `"does not destroy the existing DailyResponse when exercise.update! fails"`

Keep `"redirects with an alert when there's no exercise yet"` and `"blocks a second regeneration the same day"` — both are controller-level guards that still run before anything is enqueued.

`have_enqueued_job` needs `ActiveJob::TestHelper`, which today is included only inside `describe "POST /generate"`. Move that `include ActiveJob::TestHelper` line up to the top-level `RSpec.describe` body so both describes get it. Then add:

```ruby
    it "enqueues the job without calling the provider inline" do
      create_exercise
      allow(AiService).to receive(:for)

      expect {
        post regenerate_path
      }.to have_enqueued_job(RegenerateExerciseJob).with(user_id: user.id)

      expect(AiService).not_to have_received(:for)
      expect(response).to redirect_to(root_path)
    end

    it "claims the row so the dashboard can show it as in flight" do
      exercise = create_exercise

      post regenerate_path

      expect(exercise.reload.regenerating_since).to be_present
    end

    # An impatient second click must not enqueue a second billable generation.
    it "does not enqueue twice while a claim is already held" do
      create_exercise
      post regenerate_path

      expect { post regenerate_path }.not_to have_enqueued_job(RegenerateExerciseJob)
    end

    # A worker that died mid-job leaves a claim behind; the user must be able to
    # try again rather than being locked out for the rest of the day.
    it "lets a stale claim be reclaimed" do
      exercise = create_exercise
      exercise.update!(regenerating_since: DailyExercise::REGENERATION_STALE_AFTER.ago - 1.minute)

      expect {
        post regenerate_path
      }.to have_enqueued_job(RegenerateExerciseJob)
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/requests/daily_exercises_spec.rb -e "POST /regenerate"`
Expected: FAIL — no job is enqueued and `regenerating_since` stays nil.

- [ ] **Step 3: Rewrite the action**

Replace the body of `#regenerate` in `app/controllers/daily_exercises_controller.rb` (keep the leading comment block, updating it to describe the async flow):

```ruby
  # POST /regenerate — manually re-run today's exercise generation, capped at
  # once per day via regenerated_at. Replaces the existing DailyExercise row's
  # contents in place; never creates a second row for the same day. The provider
  # call runs on the worker, so this action never blocks on it.
  def regenerate
    exercise = current_user.daily_exercises.for_date.first
    return redirect_to root_path, alert: "No exercise set to regenerate yet." unless exercise

    unless claim_regeneration!(exercise)
      return redirect_to root_path, alert: "You've already generated a new set today."
    end

    current_user.update!(last_generation_error_date: nil, last_generation_error: nil)
    RegenerateExerciseJob.perform_later(user_id: current_user.id)
    redirect_to root_path, flash: { generating: true }
  end

  private

  # Atomic claim against a concurrent double-submit, mirroring
  # ResponsesController#claim_review!: a single UPDATE ... WHERE is serialized by
  # Postgres row locking, so only one caller can win. The same statement enforces
  # the once-per-day gate and lets an expired claim be retaken.
  def claim_regeneration!(exercise)
    DailyExercise.where(id: exercise.id, regenerated_at: nil)
                 .where("regenerating_since IS NULL OR regenerating_since < ?",
                        DailyExercise::REGENERATION_STALE_AFTER.ago)
                 .update_all(regenerating_since: Time.current) == 1
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/requests/daily_exercises_spec.rb`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/daily_exercises_controller.rb spec/requests/daily_exercises_spec.rb
git commit -m "Enqueue regeneration instead of blocking the request thread"
```

---

### Task 4: Report the in-flight state to the dashboard

**Files:**
- Modify: `app/controllers/dashboard_controller.rb:2-23` and `:30-38`
- Test: `spec/requests/dashboard_spec.rb`

**Interfaces:**
- Consumes: `DailyExercise#regenerating?` (Task 1).
- Produces: `@generating` is true while a claim is held; `GET /dashboard/status` returns `{"status":"pending"}` in that state.

- [ ] **Step 1: Write the failing tests**

Add to `spec/requests/dashboard_spec.rb`:

```ruby
  describe "while a regeneration is in flight" do
    def claimed_exercise
      DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago,
                            problem_set: { "code_review" => { "question" => "STALE-SET-MARKER" } },
                            regenerating_since: Time.current)
    end

    it "shows the spinner instead of the stale problem set" do
      claimed_exercise

      get root_path

      expect(response.body).to include("Generating your personalized exercise set")
      expect(response.body).not_to include("STALE-SET-MARKER")
    end

    # The row is present the whole time, so an exists?-only check would report
    # the regeneration finished the instant it started.
    it "reports pending rather than ready" do
      claimed_exercise

      get dashboard_status_path

      expect(JSON.parse(response.body)["status"]).to eq("pending")
    end

    it "reports ready once the claim is released" do
      exercise = claimed_exercise
      exercise.update!(regenerating_since: nil)

      get dashboard_status_path

      expect(JSON.parse(response.body)["status"]).to eq("ready")
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "while a regeneration is in flight"`
Expected: FAIL — the page renders the old problem set and `status` returns `"ready"`.

- [ ] **Step 3: Handle the state in `#show`**

In `app/controllers/dashboard_controller.rb`, insert immediately after the `@response` assignment and before the existing `return unless @exercise.nil? && ...` guard:

```ruby
    if @exercise&.regenerating?
      @generating = true
      return
    end
```

- [ ] **Step 4: Handle the state in `#status`**

Replace the body of `#status`:

```ruby
  def status
    exercise = current_user.daily_exercises.for_date.first

    if exercise&.regenerating?
      render json: { status: "pending" }
    elsif exercise
      render json: { status: "ready" }
    elsif current_user.last_generation_error_date == Date.current
      render json: { status: "failed", message: current_user.last_generation_error }
    else
      render json: { status: "pending" }
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/dashboard_controller.rb spec/requests/dashboard_spec.rb
git commit -m "Surface an in-flight regeneration on the dashboard"
```

---

### Task 5: Show a failure banner without losing the set

**Files:**
- Modify: `app/controllers/dashboard_controller.rb`, `app/views/dashboard/_exercise.html.erb:1-3`
- Test: `spec/requests/dashboard_spec.rb`

**Interfaces:**
- Consumes: `@exercise` and `current_user.last_generation_error` (existing).
- Produces: `@regeneration_failed` → `Boolean`, rendered as a banner above the problem set.

- [ ] **Step 1: Write the failing tests**

Add to `spec/requests/dashboard_spec.rb`:

```ruby
  describe "after a failed regeneration" do
    it "keeps the existing set and explains what went wrong" do
      DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago,
                            problem_set: { "code_review" => { "question" => "keep me" } })
      user.update!(last_generation_error_date: Date.current,
                   last_generation_error: "The AI provider is rate-limiting requests — try again shortly.")

      get root_path

      expect(response.body).to include("keep me")
      expect(response.body).to include("The AI provider is rate-limiting requests")
    end

    it "does not show the banner for a failure recorded on an earlier day" do
      DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago,
                            problem_set: { "code_review" => { "question" => "keep me" } })
      user.update!(last_generation_error_date: Date.current - 1, last_generation_error: "yesterday's problem")

      get root_path

      expect(response.body).not_to include("yesterday's problem")
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "after a failed regeneration"`
Expected: FAIL — the rate-limit message is absent from the body.

- [ ] **Step 3: Set the flag in `#show`**

In `app/controllers/dashboard_controller.rb`, immediately below the `@exercise&.regenerating?` block added in Task 4:

```ruby
    @regeneration_failed = @exercise.present? && current_user.last_generation_error_date == Date.current
```

- [ ] **Step 4: Render the banner**

At the very top of `app/views/dashboard/_exercise.html.erb`, above the existing `<% submitted = ... %>` line:

```erb
<% if @regeneration_failed %>
  <div class="flash alert" style="margin-bottom:1.5rem;">
    Couldn't generate a new set: <%= current_user.last_generation_error %>
  </div>
<% end %>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/dashboard_controller.rb app/views/dashboard/_exercise.html.erb spec/requests/dashboard_spec.rb
git commit -m "Explain a failed regeneration without discarding the set"
```

---

### Task 6: Poll long enough to outlast the generation budget

**Files:**
- Modify: `app/views/dashboard/_generating.html.erb:4` and `:15`
- Test: `spec/requests/dashboard_spec.rb`

**Interfaces:**
- Consumes: `AiService::GENERATION_READ_TIMEOUT`.
- Produces: the rendered poller's `MAX_ATTEMPTS` covers more wall-clock time than the worker's generation budget.

- [ ] **Step 1: Write the failing test**

Add to `spec/requests/dashboard_spec.rb`:

```ruby
  describe "the generation poller" do
    include ActiveSupport::Testing::TimeHelpers

    # The poller shipped with a fixed 40 attempts (120s) while the worker's
    # generation budget is GENERATION_READ_TIMEOUT (300s), so a slow but healthy
    # generation told the user to refresh while the job was still running.
    it "keeps polling for longer than a generation is allowed to take" do
      # A weekday with no exercise yet is the state that renders the spinner.
      travel_to Time.utc(2026, 8, 7, 12, 0, 0) do
        get root_path

        attempts = response.body[/MAX_ATTEMPTS = (\d+)/, 1].to_i
        interval = response.body[/setTimeout\(poll, (\d+)\)/, 1].to_i / 1000.0

        expect(attempts).to be_positive
        expect(attempts * interval).to be > AiService::GENERATION_READ_TIMEOUT
      end
    end
  end
```

`2026-08-07` is a Friday, and `let(:user)` has an API key but no `DailyExercise`, so `#show` takes the `@generating` branch and renders `dashboard/_generating`. Add this `describe` inside the top-level `RSpec.describe` block so it inherits `before { login_as(user) }` at line 47.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "the generation poller"`
Expected: FAIL — `120.0` is not greater than `300`.

- [ ] **Step 3: Derive the attempt count and fix the stale copy**

In `app/views/dashboard/_generating.html.erb`, replace the hint line:

```erb
  <p style="font-size:.85rem;color:var(--muted);" id="generating-hint">This usually takes under a minute — this page will update automatically.</p>
```

and replace the `MAX_ATTEMPTS` line:

```erb
  <%# Derived from the provider budget rather than hardcoded, so the poller
      cannot quietly stop covering a generation the worker is still running. %>
  const MAX_ATTEMPTS = <%= ((AiService::GENERATION_READ_TIMEOUT + 90) / 3.0).ceil %>;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "the generation poller"`
Expected: PASS — `390.0 > 300`.

- [ ] **Step 5: Commit**

```bash
git add app/views/dashboard/_generating.html.erb spec/requests/dashboard_spec.rb
git commit -m "Poll long enough to outlast the generation budget"
```

---

### Task 7: Full verification and PR

**Files:** none modified beyond fixes surfaced by the suite.

- [ ] **Step 1: Run the whole non-system suite**

Run: `bundle exec rspec --exclude-pattern "system/**/*_spec.rb"`
Expected: 0 failures. Fix any spec that asserted the old synchronous regenerate behavior — do **not** weaken an assertion to make it pass; if one must change, state why in the commit message.

- [ ] **Step 2: Run the system specs**

Run: `bundle exec rspec spec/system`
Expected: 0 failures.

- [ ] **Step 3: Lint**

Run: `bundle exec rubocop app spec`
Expected: no offenses.

- [ ] **Step 4: Confirm each new spec fails without its fix**

For each of Tasks 1–6, revert the implementation hunk, run that task's spec, confirm FAIL, then restore. A spec that passes without its fix is not testing anything.

- [ ] **Step 5: Update the project map**

In `CLAUDE.md`, update the `DailyExercisesController#regenerate` line in the architecture diagram to note the work is enqueued, and add `app/jobs/regenerate_exercise_job.rb` to the File Map.

- [ ] **Step 6: Commit and open the PR**

```bash
git add CLAUDE.md
git commit -m "Document async regeneration"
git push -u origin async-regenerate
gh pr create --base main --title "Move regeneration off the request thread"
```

The PR body must state that regenerate no longer performs provider I/O in a controller action, that a failed regeneration preserves both the set and the daily allowance, and that `SYNC_GENERATION_READ_TIMEOUT` now has no caller (see the spec's open question) so reviewers can decide whether to keep it.
