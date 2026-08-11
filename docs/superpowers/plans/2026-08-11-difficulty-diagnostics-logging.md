# Difficulty Diagnostics Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Log, in one JSON line per event, what a generation requested (skill level, reinforcement/retention/established concepts, recent performance history) and what it delivered (the generated problem set), plus a pairing of AI vs. self ratings at review time — so a week of production data can answer whether difficulty adaptation is actually working, without changing any generation behavior.

**Architecture:** Two independent logging hooks added to existing methods, following the exact pattern the codebase already uses for `AiService#log_retention`: a private method that builds a payload and writes one `Rails.logger.info` line tagged `[difficulty_diagnostics]`, called from the one place each event naturally occurs. No new classes, no shared module — the two events are correlated only by `user_id` + `date` in their JSON bodies, matching how `log_retention` already correlates.

**Tech Stack:** Ruby on Rails 8, RSpec, `Rails.logger` (STDOUT in production per `config/environments/production.rb`), stdlib `JSON`.

## Global Constraints

- Zero changes to prompt content, schema, generation logic, mastery tiers, or anything that affects what the user actually sees. This is purely observational.
- No migration, no new table, no persistence beyond the log stream.
- Log to `Rails.logger` (STDOUT), never to a file — Railway's filesystem is ephemeral, so a file would be lost on every deploy/restart.
- Every new method carries a comment stating why the instrumentation exists and what question it answers, so a future reader can tell whether it's still needed.
- Full design context: `docs/superpowers/specs/2026-08-11-difficulty-diagnostics-logging-design.md`.

---

## Task 1: Generation-time diagnostics in AiService

**Files:**
- Modify: `app/services/ai_service.rb:281-299` (`#generate_exercise`), and add a new private method near `#log_retention` (currently `app/services/ai_service.rb:618-636`)
- Test: `spec/services/ai_service_spec.rb` (new `describe` block near the existing `"retention instrumentation"` block, currently at line 1191)

**Interfaces:**
- Consumes: `DailyPlan::Result` (`third`, `reinforcement`, `due_checks`, `established` — `app/services/daily_plan.rb`), `User#recent_performance` (`app/models/user.rb:130-147`, returns an array of hashes: `date`, `feedback`, `concepts`, `scenarios`, `sections_answered`, `self_ratings`, `ai_ratings`), `User#skill_level`, the already-normalized `problem_set` hash `#generate_exercise` produces.
- Produces: nothing consumed by other tasks — this task is self-contained. `Task 2` logs a separate, uncorrelated-in-code event (correlated only by reading the two JSON lines together).

- [ ] **Step 1: Write the failing test**

Add this `describe` block to `spec/services/ai_service_spec.rb`, right after the existing `describe "retention instrumentation" do ... end` block (ends at line 1226):

```ruby
  describe "difficulty diagnostics instrumentation" do
    it "logs what was requested and what was delivered on every generation" do
      set = { "code_review" => { "concept" => "memoization", "title" => "t", "question" => "q" } }
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([ { concept: "n_plus_one", tier: "reduced" } ])

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.start_with?("[difficulty_diagnostics]")
      end

      svc.generate_exercise(user, language: "ruby_rails")

      expect(logged).not_to be_nil
      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))

      expect(payload["event"]).to eq("generation")
      expect(payload["user_id"]).to eq(user.id)
      expect(payload["date"]).to eq(Date.current.to_s)
      expect(payload["language"]).to eq("ruby_rails")
      expect(payload["requested"]["skill_level"]).to eq(user.skill_level)
      expect(payload["requested"]["reinforcement"]).to eq([ { "concept" => "n_plus_one", "tier" => "reduced" } ])
      expect(payload["requested"]).to have_key("due_checks")
      expect(payload["requested"]).to have_key("established")
      expect(payload["requested"]).to have_key("recent_performance")
      expect(payload["delivered"]).to eq(JSON.parse(set.to_json))
    end

    it "includes due retention checks and established concepts by name" do
      user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 2)
      set = { "code_review" => { "concept" => "memoization" } }
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.start_with?("[difficulty_diagnostics]")
      end

      svc.generate_exercise(user, language: "ruby_rails")

      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))
      expect(payload["requested"]["due_checks"]).to eq([ "memoization" ])
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "difficulty diagnostics instrumentation"`
Expected: FAIL — `logged` is `nil` (`NoMethodError` or a failed `not_to be_nil` on `nil.delete_prefix`), since nothing logs `[difficulty_diagnostics]` yet.

- [ ] **Step 3: Add the private method**

In `app/services/ai_service.rb`, insert this immediately after `#log_retention` (after the `end` on line 636, before the `# Subclasses must implement...` comment on line 638):

```ruby

  # Nearly all difficulty adaptation in this app is advisory — the prompt asks
  # the model to ease off reduced-tier concepts or raise the bar after a run
  # of "too easy" ratings, but nothing verifies the returned problem set
  # actually reflects that. This pairs what was requested against what was
  # delivered so a week of production entries can answer whether the loop is
  # working before changing any generation logic on a hunch. Read alongside
  # ResponsesController#log_review_diagnostics (correlated by user_id + date).
  # Safe to remove once that question is settled. See
  # docs/superpowers/specs/2026-08-11-difficulty-diagnostics-logging-design.md.
  def log_difficulty_diagnostics(user, language, plan, problem_set)
    payload = {
      event: "generation",
      user_id: user.id,
      date: Date.current.to_s,
      language: language,
      requested: {
        skill_level: user.skill_level,
        reinforcement: plan.reinforcement,
        due_checks: plan.due_checks.map(&:concept),
        established: plan.established.map(&:concept),
        recent_performance: user.recent_performance
      },
      delivered: problem_set
    }

    Rails.logger.info("[difficulty_diagnostics] #{payload.to_json}")
  end
```

- [ ] **Step 4: Call it from `#generate_exercise`**

In `app/services/ai_service.rb`, change lines 293-298 from:

```ruby
    problem_set = normalize_concepts(parse_json_object(result[:text], subject: "problem set"), language)
    normalize_answer_scaffolds!(problem_set)
    normalize_diagrams!(problem_set)
    shuffle_parsons_blocks!(problem_set)
    log_retention(user, language, plan.due_checks, problem_set)
    problem_set
```

to:

```ruby
    problem_set = normalize_concepts(parse_json_object(result[:text], subject: "problem set"), language)
    normalize_answer_scaffolds!(problem_set)
    normalize_diagrams!(problem_set)
    shuffle_parsons_blocks!(problem_set)
    log_retention(user, language, plan.due_checks, problem_set)
    log_difficulty_diagnostics(user, language, plan, problem_set)
    problem_set
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "difficulty diagnostics instrumentation"`
Expected: PASS (2 examples, 0 failures)

- [ ] **Step 6: Run the full AiService spec file to check for regressions**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: PASS, same failure count as before this change (0 new failures). The pre-existing `"retention instrumentation"` block's `expect(Rails.logger).not_to receive(:info).with(/\[retention\]/)` example must still pass — it targets `[retention]` specifically, so the new unconditional `[difficulty_diagnostics]` line does not conflict with it.

- [ ] **Step 7: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Log generation-time difficulty diagnostics"
```

---

## Task 2: Review-time diagnostics in ResponsesController

**Files:**
- Modify: `app/controllers/responses_controller.rb:98-158` (`#review`), and add a new private method near `#release_review_claim!` (currently `app/controllers/responses_controller.rb:427-429`)
- Test: `spec/requests/responses_spec.rb` (new examples inside the existing `describe "POST /responses/:id/review" do ... end` block, currently starting at line 254)

**Interfaces:**
- Consumes: `DailyResponse#ai_rating_for(section)` and `DailyResponse#self_rating_for(section)` (`app/models/daily_response.rb:89,94`), `successes` (the `Hash` of `{ section => { ok: true, review: {...} } }` already built in `#review`).
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Write the failing test**

Add these two examples inside the existing `describe "POST /responses/:id/review" do ... end` block in `spec/requests/responses_spec.rb`, right after the `"saves the ai_review from the user's configured provider"` example (after line 313):

```ruby
    it "logs the AI rating paired with the user's self-rating for each reviewed section" do
      daily_response = create_submitted_response
      daily_response.update!(section_ratings: { "code_review" => "right_level", "pattern" => "too_hard" })
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return(
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "beginner" } },
        "challenge"   => { ok: true, review: { "rating" => "solid" } }
      )
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.start_with?("[difficulty_diagnostics]")
      end

      post review_response_path(daily_response)

      expect(logged).not_to be_nil
      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))

      expect(payload["event"]).to eq("review")
      expect(payload["user_id"]).to eq(user.id)
      expect(payload["date"]).to eq(daily_response.date.to_s)
      expect(payload["sections"]).to eq(
        "code_review" => { "ai_rating" => "solid",    "self_rating" => "right_level" },
        "pattern"     => { "ai_rating" => "beginner", "self_rating" => "too_hard" },
        "challenge"   => { "ai_rating" => "solid",    "self_rating" => nil }
      )
    end

    it "does not log when every section fails" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return(
        "code_review" => { ok: false, error_code: "rate_limit", message: "slow down" },
        "pattern"     => { ok: false, error_code: "rate_limit", message: "slow down" },
        "challenge"   => { ok: false, error_code: "rate_limit", message: "slow down" }
      )
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      expect(Rails.logger).not_to receive(:info).with(/\[difficulty_diagnostics\]/)

      post review_response_path(daily_response)
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/requests/responses_spec.rb -e "logs the AI rating paired with the user's self-rating for each reviewed section"`
Expected: FAIL — `logged` is `nil`, since nothing logs `[difficulty_diagnostics]` yet.

(The second new example, `"does not log when every section fails"`, already passes before this change since nothing logs that tag at all yet — it will keep passing throughout; it exists to lock in the "no successes → no log line" behavior once Step 4 adds the call.)

- [ ] **Step 3: Add the private method**

In `app/controllers/responses_controller.rb`, insert this immediately after `#release_review_claim!` (after the `end` on line 429, before `def zero_success_alert(failures)` on line 431):

```ruby

  # Nearly all difficulty adaptation in this app is advisory; nothing
  # verifies the AI's rating and the engineer's own self-rating ever agree,
  # or that either one shifts with how the prompt says it should. This pairs
  # both per section so a week of entries can be read alongside
  # AiService#log_difficulty_diagnostics (correlated by user_id + date) as
  # "here's what we asked for, here's what we got, here's how it was rated."
  # Safe to remove once that question is settled. See
  # docs/superpowers/specs/2026-08-11-difficulty-diagnostics-logging-design.md.
  def log_review_diagnostics(response, sections)
    payload = {
      event: "review",
      user_id: response.user_id,
      date: response.date.to_s,
      sections: sections.index_with { |section|
        { ai_rating: response.ai_rating_for(section), self_rating: response.self_rating_for(section) }
      }
    }

    Rails.logger.info("[difficulty_diagnostics] #{payload.to_json}")
  end
```

- [ ] **Step 4: Call it from `#review`**

In `app/controllers/responses_controller.rb`, change lines 136-138 from:

```ruby
      @response.save!
    end
    release_review_claim!
```

to:

```ruby
      @response.save!
    end
    log_review_diagnostics(@response, successes.keys) if successes.any?
    release_review_claim!
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/requests/responses_spec.rb -e "POST /responses/:id/review"`
Expected: PASS (all examples in that block, including the two new ones)

- [ ] **Step 6: Run the full responses request spec to check for regressions**

Run: `bundle exec rspec spec/requests/responses_spec.rb`
Expected: PASS, same failure count as before this change (0 new failures)

- [ ] **Step 7: Commit**

```bash
git add app/controllers/responses_controller.rb spec/requests/responses_spec.rb
git commit -m "Log review-time difficulty diagnostics"
```

---

## Final check

- [ ] Run the full suite once more to confirm nothing elsewhere depends on `Rails.logger` call counts during generation or review: `bundle exec rspec spec/services/ai_service_spec.rb spec/requests/responses_spec.rb`
- [ ] Confirm no prompt string, schema, or generation-affecting code changed: `git diff main --stat` should show only `ai_service.rb`, `responses_controller.rb`, and their two spec files.
