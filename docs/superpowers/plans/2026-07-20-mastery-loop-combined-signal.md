# Mastery Loop Combined Signal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the mastery loop reinforce a concept when either the user's self-rating or the AI review's per-section rating indicates a struggle, and only mark it mastered when both signals explicitly agree the user is solid.

**Architecture:** Add small favorable/unfavorable predicates to `DailyResponse` for both signals (self-rating and per-section AI rating), reuse them from a new `User#concepts_needing_reinforcement` that resolves each concept on its single most-recent occurrence, feed that computed list plus a richer per-section history line into `AiService#build_exercise_prompt`, and reuse the same predicates in a new UI note that surfaces the disagreement case on the review page.

**Tech Stack:** Ruby on Rails 8.0.5, RSpec, PostgreSQL (jsonb columns `ai_review`/`concept_tags`, no migration).

**Reference:** Design spec at `docs/superpowers/specs/2026-07-20-mastery-loop-combined-signal-design.md`. Read it if anything below is ambiguous — this plan implements it exactly.

## Global Constraints

- No migration. All data (`ai_review`, `concept_tags`, `rating`) already exists on `DailyResponse`.
- No changes to magic-link auth, Resend/SMTP, `/test_login`, timezone work, the language-preference spec, `ConceptReference` generation/storage, the suggested-concepts admin work, or the architecture section's own schema/vocabulary.
- Mastery rule (apply exactly, resolved on each concept's single most-recent occurrence, not cumulative): `self_rating.nil? && ai_rating.nil?` → out of scope (excluded, like an unrated concept today); `self_rating favorable (right_level/too_easy) && ai_rating favorable (solid/strong)` → mastered (excluded); everything else → needs reinforcement.
- Run `bundle exec rspec` (whole suite, not just changed files) at the end of every task in this plan — this codebase's CI runs the full suite on every PR, and each task here touches shared logic (`DailyResponse`, `User#recent_performance`) that other specs depend on.

---

### Task 1: `DailyResponse` signal predicates

**Files:**
- Modify: `app/models/daily_response.rb`
- Test: `spec/models/daily_response_spec.rb`

**Interfaces:**
- Produces (used by Tasks 2, 3, 5): `DailyResponse#self_rating_favorable?`, `#self_rating_unfavorable?`, `#ai_rating_for(section)`, `#ai_rating_favorable?(section)`, `#ai_rating_unfavorable?(section)`, and constant `DailyResponse::SELF_RATING_LABELS` (`Hash`, keys `"too_easy"`/`"right_level"`/`"too_hard"` → display strings `"too easy"`/`"just right"`/`"too hard"`, matching the copy already used in `app/views/responses/_feedback_form.html.erb:5-7`) plus `#self_rating_label` (`SELF_RATING_LABELS[rating]`, nil when unrated).

- [ ] **Step 1: Write the failing tests**

Add to `spec/models/daily_response_spec.rb`, inside the `RSpec.describe DailyResponse` block, after the existing `describe "#answered_sections"` block (before the file's final `end`):

```ruby
  describe "#self_rating_favorable? and #self_rating_unfavorable?" do
    it "treats right_level and too_easy as favorable, too_hard as unfavorable, nil as neither" do
      favorable_right_level = user.daily_responses.create!(daily_exercise: exercise, date: Date.current, answers: {}, rating: :right_level)
      favorable_too_easy    = user.daily_responses.create!(daily_exercise: exercise, date: Date.current + 1, answers: {}, rating: :too_easy)
      unfavorable           = user.daily_responses.create!(daily_exercise: exercise, date: Date.current + 2, answers: {}, rating: :too_hard)
      unrated               = user.daily_responses.create!(daily_exercise: exercise, date: Date.current + 3, answers: {})

      expect(favorable_right_level.self_rating_favorable?).to be(true)
      expect(favorable_too_easy.self_rating_favorable?).to be(true)
      expect(unfavorable.self_rating_favorable?).to be(false)
      expect(unrated.self_rating_favorable?).to be(false)

      expect(unfavorable.self_rating_unfavorable?).to be(true)
      expect(favorable_right_level.self_rating_unfavorable?).to be(false)
      expect(unrated.self_rating_unfavorable?).to be(false)
    end
  end

  describe "#ai_rating_for, #ai_rating_favorable?, and #ai_rating_unfavorable?" do
    it "reads the per-section rating out of ai_review, nil-safe when unreviewed or the section is missing" do
      reviewed = user.daily_responses.create!(
        daily_exercise: exercise, date: Date.current, answers: {},
        ai_review: { "code_review" => { "rating" => "developing" }, "pattern" => { "rating" => "strong" } }
      )
      unreviewed = user.daily_responses.create!(daily_exercise: exercise, date: Date.current + 1, answers: {})

      expect(reviewed.ai_rating_for("code_review")).to eq("developing")
      expect(reviewed.ai_rating_favorable?("code_review")).to be(false)
      expect(reviewed.ai_rating_unfavorable?("code_review")).to be(true)

      expect(reviewed.ai_rating_for("pattern")).to eq("strong")
      expect(reviewed.ai_rating_favorable?("pattern")).to be(true)
      expect(reviewed.ai_rating_unfavorable?("pattern")).to be(false)

      expect(reviewed.ai_rating_for("challenge")).to be_nil
      expect(reviewed.ai_rating_favorable?("challenge")).to be(false)
      expect(reviewed.ai_rating_unfavorable?("challenge")).to be(false)

      expect(unreviewed.ai_rating_for("code_review")).to be_nil
      expect(unreviewed.ai_rating_favorable?("code_review")).to be(false)
      expect(unreviewed.ai_rating_unfavorable?("code_review")).to be(false)
    end
  end

  describe "#self_rating_label" do
    it "matches the feedback form's copy and is nil when unrated" do
      right_level = user.daily_responses.create!(daily_exercise: exercise, date: Date.current, answers: {}, rating: :right_level)
      unrated     = user.daily_responses.create!(daily_exercise: exercise, date: Date.current + 1, answers: {})

      expect(right_level.self_rating_label).to eq("just right")
      expect(unrated.self_rating_label).to be_nil
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/models/daily_response_spec.rb`
Expected: 3 failures with `NoMethodError: undefined method 'self_rating_favorable?'` (and similarly for the other new methods).

- [ ] **Step 3: Implement the predicates**

In `app/models/daily_response.rb`, add after the `enum :rating, ...` line and before `validates :date, ...`:

```ruby
  SELF_RATING_LABELS = { "too_easy" => "too easy", "right_level" => "just right", "too_hard" => "too hard" }.freeze

  AI_RATING_FAVORABLE   = %w[solid strong].freeze
  AI_RATING_UNFAVORABLE = %w[beginner developing].freeze
```

Then add these methods after `def reviewed? = ai_review.present?`:

```ruby
  def self_rating_label       = SELF_RATING_LABELS[rating]
  def self_rating_favorable?  = rating_right_level? || rating_too_easy?
  def self_rating_unfavorable? = rating_too_hard?

  def ai_rating_for(section)        = ai_review&.dig(section.to_s, "rating")
  def ai_rating_favorable?(section)   = AI_RATING_FAVORABLE.include?(ai_rating_for(section))
  def ai_rating_unfavorable?(section) = AI_RATING_UNFAVORABLE.include?(ai_rating_for(section))
```

The full method block area should now read:

```ruby
  enum :rating, { too_easy: 0, right_level: 1, too_hard: 2 }, prefix: true

  SELF_RATING_LABELS = { "too_easy" => "too easy", "right_level" => "just right", "too_hard" => "too hard" }.freeze

  AI_RATING_FAVORABLE   = %w[solid strong].freeze
  AI_RATING_UNFAVORABLE = %w[beginner developing].freeze

  validates :date, uniqueness: { scope: :user_id }

  # Ordered field → label map for rendering ai_review sections — shared by the
  # shared/_ai_review partial and ReviewMailer so the copy lives in one place.
  # "rating" (badge) and "improved_code" (code block) render separately.
  AI_REVIEW_FIELDS = {
    "correct"          => "What you got right",
    "missed"           => "What you missed",
    "better_questions" => "Questions to ask yourself",
    "next_step"        => "Next step"
  }.freeze

  def submitted? = submitted_at.present?
  def reviewed?  = ai_review.present?

  def self_rating_label       = SELF_RATING_LABELS[rating]
  def self_rating_favorable?  = rating_right_level? || rating_too_easy?
  def self_rating_unfavorable? = rating_too_hard?

  def ai_rating_for(section)        = ai_review&.dig(section.to_s, "rating")
  def ai_rating_favorable?(section)   = AI_RATING_FAVORABLE.include?(ai_rating_for(section))
  def ai_rating_unfavorable?(section) = AI_RATING_UNFAVORABLE.include?(ai_rating_for(section))

  # Answer keys with substantive content — same >10-char heuristic the
  # dashboard progress bar uses.
  def answered_sections
    answers.select { |_, v| v.to_s.strip.length > 10 }.keys
  end

  def completeness
    (answered_sections.size / 3.0 * 100).round
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/daily_response_spec.rb`
Expected: all examples pass (0 failures).

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: all examples pass — these are new additive methods, nothing existing should break.

- [ ] **Step 6: Commit**

```bash
git add app/models/daily_response.rb spec/models/daily_response_spec.rb
git commit -m "Add self-rating and per-section AI-rating predicates to DailyResponse

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 2: `User#recent_performance` surfaces per-section AI ratings

**Files:**
- Modify: `app/models/user.rb:57-76` (the `recent_performance` method and its private section starting at line 108)
- Test: `spec/models/user_spec.rb`

**Interfaces:**
- Consumes: `DailyResponse#ai_rating_for(section)` (Task 1).
- Produces (used by Task 4): each `User#recent_performance` entry gains a `:section_ratings` key — `Hash` of `section_name (String) => ai_rating (String) or absent if unreviewed`. Also produces a new private `User#recent_daily_responses(limit)` helper (used by Task 3).

- [ ] **Step 1: Write the failing test**

Add to `spec/models/user_spec.rb`, immediately after the existing `describe "#recent_performance scenarios"` block (before `describe "#language_for_today"`):

```ruby
  describe "#recent_performance section_ratings" do
    it "surfaces each section's AI-assessed rating alongside the self-rating, nil-safe when unreviewed" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {}, "pattern" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 },
                            concept_tags: { "code_review" => "n_plus_one", "pattern" => "memoization" },
                            ai_review: { "code_review" => { "rating" => "developing" } })

      expect(user.recent_performance.first[:section_ratings]).to eq({ "code_review" => "developing" })
    end

    it "is an empty hash when the response was never reviewed" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 },
                            concept_tags: { "code_review" => "n_plus_one" })

      expect(user.recent_performance.first[:section_ratings]).to eq({})
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/user_spec.rb -e "#recent_performance section_ratings"`
Expected: FAIL — `key not found: :section_ratings` (the entry hash has no such key yet).

- [ ] **Step 3: Implement `section_ratings` and the shared query helper**

In `app/models/user.rb`, replace the `recent_performance` method (currently lines 57-76):

```ruby
  # ── Recent performance for prompt context ─────────────────────────────────
  # Last N sessions by count, not a calendar window — matches the "last 10
  # sessions" contract embedded verbatim in AiService's generation prompt.
  def recent_performance(limit: 10)
    daily_responses
      .includes(:daily_exercise)
      .order(date: :desc)
      .limit(limit)
      .map do |r|
        problem_set = r.daily_exercise&.problem_set || {}
        scenarios = %w[code_review pattern challenge architecture].filter_map do |section|
          problem_set.dig(section, "scenario").presence
        end
        {
          date:          r.date.to_s,
          rating:        r.rating,
          feedback:      r.feedback_text,
          concepts:      r.concept_tags,
          scenarios:     scenarios,
          sections_answered: r.answered_sections.size
        }
      end
  end
```

with:

```ruby
  # ── Recent performance for prompt context ─────────────────────────────────
  # Last N sessions by count, not a calendar window — matches the "last 10
  # sessions" contract embedded verbatim in AiService's generation prompt.
  def recent_performance(limit: 10)
    recent_daily_responses(limit).map do |r|
      problem_set = r.daily_exercise&.problem_set || {}
      scenarios = %w[code_review pattern challenge architecture].filter_map do |section|
        problem_set.dig(section, "scenario").presence
      end
      # AI-assessed rating per tagged section, empty when the response was
      # never reviewed — surfaced alongside the day's self-rating so
      # AiService can show both signals side by side in the prompt.
      section_ratings = r.concept_tags.keys.index_with { |section| r.ai_rating_for(section) }.compact
      {
        date:          r.date.to_s,
        rating:        r.rating,
        feedback:      r.feedback_text,
        concepts:      r.concept_tags,
        scenarios:     scenarios,
        sections_answered: r.answered_sections.size,
        section_ratings: section_ratings
      }
    end
  end
```

Then, in the `private` section (currently just `time_zone_must_be_loadable`, starting at line 108), add the shared query helper above it:

```ruby
  private

  # Shared by #recent_performance and #concepts_needing_reinforcement so
  # neither issues its own duplicate "last N sessions" query.
  def recent_daily_responses(limit)
    daily_responses.includes(:daily_exercise).order(date: :desc).limit(limit)
  end

  def time_zone_must_be_loadable
    return if time_zone.blank? # blank/nil = not yet detected; allowed
    errors.add(:time_zone, "is not a valid time zone") if Time.find_zone(time_zone).nil?
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/models/user_spec.rb -e "#recent_performance section_ratings"`
Expected: both examples pass.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: all examples pass — `recent_performance`'s existing keys (`date`, `rating`, `feedback`, `concepts`, `scenarios`, `sections_answered`) are unchanged, only a new key was added, so the existing `#recent_performance sections_answered`, `#recent_performance concepts`, and `#recent_performance scenarios` specs should still pass unmodified.

- [ ] **Step 6: Commit**

```bash
git add app/models/user.rb spec/models/user_spec.rb
git commit -m "Surface per-section AI ratings in User#recent_performance

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 3: `User#concepts_needing_reinforcement`

**Files:**
- Modify: `app/models/user.rb` (add new public method, near `recent_performance`)
- Test: `spec/models/user_spec.rb`

**Interfaces:**
- Consumes: `User#recent_daily_responses(limit)` (Task 2, private helper — same class, so directly callable), `DailyResponse#self_rating_favorable?`/`#ai_rating_favorable?(section)` (Task 1).
- Produces (used by Task 4): `User#concepts_needing_reinforcement(limit: 10)` → `Array<String>` of concept names still needing reinforcement, most-recent-occurrence-first, deduplicated.

- [ ] **Step 1: Write the failing tests**

Add to `spec/models/user_spec.rb`, immediately after the new `describe "#recent_performance section_ratings"` block from Task 2:

```ruby
  describe "#concepts_needing_reinforcement" do
    it "flags a concept whose most recent self-rating was too_hard, even with no AI review" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :too_hard,
                            concept_tags: { "code_review" => "n_plus_one" })

      expect(user.concepts_needing_reinforcement).to eq([ "n_plus_one" ])
    end

    it "flags a concept the AI rated beginner/developing even when the self-rating was favorable (the core gap this fix closes)" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :right_level,
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "developing" } })

      expect(user.concepts_needing_reinforcement).to eq([ "n_plus_one" ])
    end

    it "keeps reinforcing when self-rating is unfavorable even if the AI review was favorable" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :too_hard,
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "solid" } })

      expect(user.concepts_needing_reinforcement).to eq([ "n_plus_one" ])
    end

    it "excludes a concept once both self-rating and AI review explicitly agree it's solid" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :too_easy,
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "strong" } })

      expect(user.concepts_needing_reinforcement).to eq([])
    end

    it "does not treat an unreviewed section as mastered, even with a favorable self-rating" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :right_level,
                            concept_tags: { "code_review" => "n_plus_one" })

      expect(user.concepts_needing_reinforcement).to eq([ "n_plus_one" ])
    end

    it "excludes a concept with no self-rating and no AI review at all, same as an unrated concept today" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 },
                            concept_tags: { "code_review" => "n_plus_one" })

      expect(user.concepts_needing_reinforcement).to eq([])
    end

    it "resolves each concept on its most recent occurrence, ignoring older history" do
      user = create_user
      older_exercise = DailyExercise.create!(user: user, date: Date.current - 1,
                                              problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: older_exercise, date: Date.current - 1,
                            answers: { "code_review" => "x" * 20 }, rating: :too_hard,
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "beginner" } })

      newer_exercise = DailyExercise.create!(user: user, date: Date.current,
                                              problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: newer_exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :too_easy,
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "strong" } })

      expect(user.concepts_needing_reinforcement).to eq([])
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/models/user_spec.rb -e "#concepts_needing_reinforcement"`
Expected: FAIL — `NoMethodError: undefined method 'concepts_needing_reinforcement'`.

- [ ] **Step 3: Implement `concepts_needing_reinforcement`**

In `app/models/user.rb`, add this public method immediately after `recent_performance` (before the `# ── Language preference ──` comment):

```ruby
  # Concepts still needing reinforcement, resolved on each concept's single
  # most-recent occurrence — not cumulative history, so a concept mastered
  # weeks ago never resurfaces because of an old bad day. Mastery requires
  # both signals to explicitly agree the user is solid; an absent signal
  # never counts toward mastery (uncertain data defaults to reinforcement).
  # Total absence of both signals is out of scope, same as an unrated
  # concept today. See docs/superpowers/specs/2026-07-20-mastery-loop-combined-signal-design.md.
  def concepts_needing_reinforcement(limit: 10)
    resolved = {}
    reinforcement = []

    recent_daily_responses(limit).each do |r|
      r.concept_tags.each do |section, concept|
        next if concept.blank? || resolved.key?(concept)
        resolved[concept] = true

        next if r.rating.nil? && r.ai_rating_for(section).nil? # out of scope, no info

        mastered = r.self_rating_favorable? && r.ai_rating_favorable?(section)
        reinforcement << concept unless mastered
      end
    end

    reinforcement
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/user_spec.rb -e "#concepts_needing_reinforcement"`
Expected: all 7 examples pass.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: all examples pass.

- [ ] **Step 6: Commit**

```bash
git add app/models/user.rb spec/models/user_spec.rb
git commit -m "Add User#concepts_needing_reinforcement combining self-rating and AI review

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 4: `AiService#build_exercise_prompt` uses the combined signal

**Files:**
- Modify: `app/services/ai_service.rb:217-267` (the `build_exercise_prompt` method)
- Test: `spec/services/ai_service_spec.rb`

**Interfaces:**
- Consumes: `User#recent_performance` entries' new `:section_ratings` key (Task 2), `User#concepts_needing_reinforcement` (Task 3).
- Produces: no new public interface — this is the final consumer of the personalization data for prompt text.

- [ ] **Step 1: Write the failing/updated tests**

In `spec/services/ai_service_spec.rb`, find this existing test (inside `describe "#build_exercise_prompt"`):

```ruby
    it "embeds the vocabulary, the mastery loop, and per-session concepts with correct rating labels" do
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :too_hard,
                            concept_tags: { "code_review" => "n_plus_one" })

      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include(AiService::RAILS_CONCEPTS.join(", "))
      expect(prompt).to include("mastery signal")
      expect(prompt).to include("concepts: n_plus_one")
      expect(prompt).to include("too hard")
      expect(prompt).not_to include("unrated")
    end
```

Replace it with (format changed: `concepts: n_plus_one` → `code_review→n_plus_one (unreviewed)`; `mastery signal` phrase removed from the rewritten instruction, replaced by the computed reinforcement line; self-rating now prefixed with `self:`):

```ruby
    it "embeds the vocabulary, the mastery loop, and per-session concepts with correct rating labels" do
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :too_hard,
                            concept_tags: { "code_review" => "n_plus_one" })

      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include(AiService::RAILS_CONCEPTS.join(", "))
      expect(prompt).to include("Mastery loop")
      expect(prompt).to include("code_review→n_plus_one (unreviewed)")
      expect(prompt).to include("self: too hard")
      expect(prompt).to include("Concepts needing reinforcement right now: n_plus_one")
      expect(prompt).not_to include("unrated")
    end

    it "shows the AI's per-section rating alongside the concept when the response was reviewed" do
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :right_level,
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "developing" } })

      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("code_review→n_plus_one (ai: developing)")
      expect(prompt).to include("Concepts needing reinforcement right now: n_plus_one")
    end

    it "reports no concepts needing reinforcement when history is empty" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("Concepts needing reinforcement right now: none")
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "#build_exercise_prompt"`
Expected: the updated first test fails on the new assertions (old format still in place); the two new tests fail the same way.

- [ ] **Step 3: Rewrite `build_exercise_prompt`'s history/reinforcement text and mastery-loop instruction**

In `app/services/ai_service.rb`, replace the `build_exercise_prompt` method (currently lines 217-267):

```ruby
  def build_exercise_prompt(user, language = "ruby_rails")
    history = user.recent_performance

    history_text = if history.empty?
      "No history yet — this is their first exercise set."
    else
      history.map { |h|
        rating_label = RATING_LABELS[h[:rating]] || "unrated"
        feedback     = h[:feedback].present? ? " | Feedback: \"#{h[:feedback]}\"" : ""
        concepts     = h[:concepts].respond_to?(:values) ? h[:concepts].values.compact.uniq : []
        concept_text = concepts.any? ? " | concepts: #{concepts.join(', ')}" : ""
        framings     = h[:scenarios].presence || []
        framing_text = framings.any? ? " | framings: #{framings.join('; ')}" : ""
        "#{h[:date]}: #{h[:sections_answered]}/3 sections answered | #{rating_label}#{concept_text}#{framing_text}#{feedback}"
      }.join("\n")
    end

    config      = config_for(language)
    label       = config[:label]
    focus       = user.focus_areas.any? ? user.focus_areas.join(", ") : "general #{label} patterns"
    concepts    = config[:concepts]

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
      - The code_review snippet must be realistic #{label} code — not toy examples.
      - The challenge starter_code should give enough scaffold to get started without giving away the answer.
      - Rotate between topics across sessions — avoid the same pattern two days in a row.
      - Vary the concrete business-domain scenario and code structure across sessions, not just the concept — do not reuse the class/method names or narrative framing shown in the "framings:" notes above.
      - Each teaching_note must point toward how to think about the problem or the right question to ask — one or two sentences, never the full answer.
      - Choose each section's concept from this fixed vocabulary, exactly one per section: #{concepts.join(", ")}
      - Mastery loop: for any concept whose most recent rating was "too hard", reintroduce that concept in this set with a different code example and framing — same underlying concept, never a repeat of the same snippet. Keep reintroducing it in every subsequent set until the user rates a set containing it "right level" or "too easy"; that rating is the mastery signal that ends reinforcement for that concept.
      - Concepts most recently rated "too easy" must not repeat within the same week.
      - Concepts most recently rated "right level" have no special weighting.

      Return JSON matching this schema exactly:
      #{exercise_schema_for(language)}
    PROMPT
  end
```

with:

```ruby
  def build_exercise_prompt(user, language = "ruby_rails")
    history = user.recent_performance

    history_text = if history.empty?
      "No history yet — this is their first exercise set."
    else
      history.map { |h|
        rating_label = RATING_LABELS[h[:rating]] || "unrated"
        feedback     = h[:feedback].present? ? " | Feedback: \"#{h[:feedback]}\"" : ""
        pairs = h[:concepts].respond_to?(:each_pair) ? h[:concepts].each_pair.filter_map { |section, concept|
          next if concept.blank?
          ai_rating = h[:section_ratings][section]
          ai_text   = ai_rating ? "(ai: #{ai_rating})" : "(unreviewed)"
          "#{section}\u2192#{concept} #{ai_text}"
        } : []
        concept_text = pairs.any? ? " | #{pairs.join(', ')}" : ""
        framings     = h[:scenarios].presence || []
        framing_text = framings.any? ? " | framings: #{framings.join('; ')}" : ""
        "#{h[:date]}: #{h[:sections_answered]}/3 sections answered | self: #{rating_label}#{concept_text}#{framing_text}#{feedback}"
      }.join("\n")
    end

    reinforcement_list = user.concepts_needing_reinforcement
    reinforcement_text = reinforcement_list.any? ? reinforcement_list.join(", ") : "none"

    config      = config_for(language)
    label       = config[:label]
    focus       = user.focus_areas.any? ? user.focus_areas.join(", ") : "general #{label} patterns"
    concepts    = config[:concepts]

    <<~PROMPT
      Generate a daily Code Gym exercise set for this engineer.

      Engineer profile:
      - Name: #{user.name}
      - Skill level: #{user.skill_level} (beginner → developing → solid → strong)
      - Priority focus areas: #{focus}

      Recent performance (last 10 sessions):
      #{history_text}

      Concepts needing reinforcement right now: #{reinforcement_text}

      Instructions:
      - If they've been rating exercises "too easy", increase difficulty and reduce explanation in the reference.
      - If they've been rating "too hard" or skipping sections, simplify and add more scaffolding.
      - Prioritize focus areas they've missed or rated hard recently.
      - The code_review snippet must be realistic #{label} code — not toy examples.
      - The challenge starter_code should give enough scaffold to get started without giving away the answer.
      - Rotate between topics across sessions — avoid the same pattern two days in a row.
      - Vary the concrete business-domain scenario and code structure across sessions, not just the concept — do not reuse the class/method names or narrative framing shown in the "framings:" notes above.
      - Each teaching_note must point toward how to think about the problem or the right question to ask — one or two sentences, never the full answer.
      - Choose each section's concept from this fixed vocabulary, exactly one per section: #{concepts.join(", ")}
      - Mastery loop: reintroduce every concept listed as "needing reinforcement right now" above in this set, with a different code example and framing — same underlying concept, never a repeat of the same snippet. A concept only stops needing reinforcement once both signals agree the user is solid: their self-rating was "right level"/"too easy" and the AI review rated that section "solid"/"strong". If the two signals disagree, or one is missing (e.g. never reviewed), keep reinforcing — do not treat that as mastery.
      - Concepts most recently rated "too easy" must not repeat within the same week.
      - Concepts most recently rated "right level" have no special weighting.

      Return JSON matching this schema exactly:
      #{exercise_schema_for(language)}
    PROMPT
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/ai_service_spec.rb`
Expected: all examples in the file pass, including the "includes recent problem framings..." test (unaffected — it has no `concept_tags`, so `pairs` is empty and the concept segment stays blank, same as before) and the JS-vocabulary/default-language tests (unaffected — no history in those, so `history_text` short-circuits to "No history yet...").

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: all examples pass.

- [ ] **Step 6: Commit**

```bash
git add app/services/ai_service.rb spec/services/ai_service_spec.rb
git commit -m "Feed the combined reinforcement signal into the generation prompt

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 5: Transparency note on the review page

**Files:**
- Modify: `app/views/shared/_ai_review.html.erb`
- Modify: `config/locales/en.yml:36-39` (the `review:` scope)
- Test: `spec/requests/dashboard_spec.rb`

**Interfaces:**
- Consumes: `DailyResponse#self_rating_favorable?`, `#ai_rating_unfavorable?(section)`, `#self_rating_label` (Task 1).
- Produces: no new public interface — this is a leaf UI change. Renders identically wherever `shared/_ai_review` is used (dashboard submitted state and the `responses#show` review page, both via `responses/_submission`), so no duplication.

- [ ] **Step 1: Write the failing tests**

Add to `spec/requests/dashboard_spec.rb`, immediately after the existing `it "renders the review with the keys review_response actually returns"` test (around line 91):

```ruby
  it "shows a calibration note when the self-rating was favorable but the AI rated that section beginner/developing" do
    resp = create_response(create_exercise, ai_review: sample_review)
    resp.update!(rating: :right_level)
    # sample_review's "pattern" section is rated "developing" — the disagreement case
    get root_path
    expect(response.body).to include("You rated this")
    expect(response.body).to include("just right")
  end

  it "shows the calibration note exactly once, only for the section the AI rated poorly" do
    resp = create_response(create_exercise, ai_review: sample_review)
    resp.update!(rating: :right_level)
    # code_review is "solid" and challenge is "strong" in sample_review — no note for those
    get root_path
    expect(response.body.scan("You rated this").size).to eq(1)
  end

  it "does not show the calibration note when the response was never self-rated" do
    create_response(create_exercise, ai_review: sample_review)
    get root_path
    expect(response.body).not_to include("You rated this")
  end

  it "does not show the calibration note when self-rating is too_hard, even if a section was rated poorly" do
    resp = create_response(create_exercise, ai_review: sample_review)
    resp.update!(rating: :too_hard)
    get root_path
    expect(response.body).not_to include("You rated this")
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "calibration note"`
Expected: the first two tests FAIL (no note rendered yet); the last two already pass trivially (nothing to assert against) — that's fine, they'll stay green as regression guards once the note exists.

- [ ] **Step 3: Add the I18n copy**

In `config/locales/en.yml`, in the `review:` scope (currently lines 36-39):

```yaml
  review:
    get_button: "Get %{provider} review →"
    heading: "%{provider}'s Review"
    history_summary: "%{provider}'s review"
```

add a new key:

```yaml
  review:
    get_button: "Get %{provider} review →"
    heading: "%{provider}'s Review"
    history_summary: "%{provider}'s review"
    calibration_note: "You rated this \"%{rating}\" — the review suggests there's more to work on here."
```

- [ ] **Step 4: Render the note in the shared partial**

In `app/views/shared/_ai_review.html.erb`, currently:

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

replace with (adds the note right after the heading, before the review fields — fires only for the exact favorable-self/unfavorable-AI disagreement, not for every AI-rated section):

```erb
<% response.ai_review.each do |section, fb| %>
  <% next unless fb.is_a?(Hash) %>
  <div class="review-block">
    <h4><%= section.humanize %><% if fb["rating"].present? %><span class="review-rating"><%= fb["rating"] %></span><% end %></h4>
    <% if response.self_rating_favorable? && response.ai_rating_unfavorable?(section) %>
      <p class="calibration-note"><%= t("review.calibration_note", rating: response.self_rating_label) %></p>
    <% end %>
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

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: all examples in the file pass, including the four calibration-note tests and every pre-existing test in the file (the note is additive markup gated on a condition that's false in all pre-existing fixtures, since none of them set `rating:`).

- [ ] **Step 6: Run the full suite**

Run: `bundle exec rspec`
Expected: all examples pass.

- [ ] **Step 7: Commit**

```bash
git add app/views/shared/_ai_review.html.erb config/locales/en.yml spec/requests/dashboard_spec.rb
git commit -m "Show a calibration note when self-rating and AI review disagree

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 6: Final full-suite verification

**Files:** none (verification only)

- [ ] **Step 1: Run the entire test suite**

Run: `bundle exec rspec`
Expected: all examples pass, 0 failures. Note the total example count for the commit message.

- [ ] **Step 2: Spot-check the rendered prompt matches the design spec's validated example**

Run: `bundle exec rails runner -e test` is not needed — instead, run the three `AiService` tests added in Task 4 individually with `-f documentation` to read their output structure:

Run: `bundle exec rspec spec/services/ai_service_spec.rb -e "#build_exercise_prompt" -f documentation`
Expected: all pass, descriptions read correctly (e.g. "shows the AI's per-section rating alongside the concept when the response was reviewed").

- [ ] **Step 3: Confirm no unrelated files changed**

Run: `git diff --stat main...HEAD` (or the appropriate base branch)
Expected: only the files listed in Tasks 1-5 appear — no changes to auth, mailers, timezone, `ConceptReference`, suggested-concepts, or the architecture section's schema/vocabulary, per the Global Constraints.
