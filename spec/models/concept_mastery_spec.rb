require "rails_helper"

RSpec.describe ConceptMastery, type: :model do
  let(:user) { User.create!(email: "cm@example.com", name: "CM") }

  # Builds a reviewed response tagging `concept` on code_review with the given
  # self + AI ratings, then runs the mastery evaluation for it.
  def review!(concept:, self_rating:, ai_rating:, date: Date.current, section: "code_review")
    exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: { section => { "concept" => concept } })
    response = user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: { section => "x" * 20 },
      section_ratings: { section => self_rating },
      concept_tags: { section => concept },
      ai_review: { section => { "rating" => ai_rating } })
    described_class.record_review!(response, sections: response.concept_tags.keys, apply_session_countdown: true)
    user.concept_masteries.find_by(concept: concept, language: "ruby_rails")
  end

  it "records last_rating with no step-down on the first evaluation (baseline)" do
    cm = review!(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing")
    expect(cm.tier).to eq("standard")
    expect(cm.streak).to eq(0)
    expect(cm.last_rating).to eq("developing")
  end

  it "resets streak when improving (AI rating strictly better than last time)" do
    review!(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing", date: Date.current - 2)
    cm = review!(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "solid", date: Date.current - 1)
    expect(cm.streak).to eq(0)
    expect(cm.last_rating).to eq("solid")
  end

  it "steps Standard → Reduced after 3 stagnant attempts" do
    4.times { |i| review!(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing", date: Date.current - (4 - i)) }
    cm = user.concept_masteries.find_by(concept: "n_plus_one", language: "ruby_rails")
    # attempt1 baseline (streak 0), attempts 2/3/4 stagnant → streak hits 3 → reduced, streak reset 0
    expect(cm.tier).to eq("reduced")
    expect(cm.streak).to eq(0)
  end

  it "steps Reduced → Paused after 2 more stagnant attempts, with a 2-session cooldown" do
    # 4 attempts to reach reduced, then 2 more stagnant
    6.times { |i| review!(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing", date: Date.current - (6 - i)) }
    cm = user.concept_masteries.find_by(concept: "n_plus_one", language: "ruby_rails")
    expect(cm.tier).to eq("paused")
    expect(cm.cooldown_remaining).to eq(2)
  end

  it "counts a paused cooldown down only on reviewed sessions and returns at Reduced" do
    6.times { |i| review!(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing", date: Date.current - (10 - i)) }
    # two unrelated reviewed sessions (different concept) burn the cooldown
    review!(concept: "memoization", self_rating: "right_level", ai_rating: "solid", date: Date.current - 3)
    review!(concept: "memoization", self_rating: "right_level", ai_rating: "solid", date: Date.current - 2)
    cm = user.concept_masteries.find_by(concept: "n_plus_one", language: "ruby_rails")
    expect(cm.tier).to eq("reduced")
    expect(cm.cooldown_remaining).to eq(0)
  end

  it "resets to Standard on full mastery from any tier" do
    4.times { |i| review!(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing", date: Date.current - (5 - i)) } # → reduced
    cm = review!(concept: "n_plus_one", self_rating: "right_level", ai_rating: "strong", date: Date.current)
    expect(cm.tier).to eq("standard")
    expect(cm.streak).to eq(0)
    expect(cm.cooldown_remaining).to eq(0)
  end

  it "treats a same-day multi-section concept as one evaluation, least-favorable wins" do
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "concept" => "n_plus_one" }, "pattern" => { "concept" => "n_plus_one" } })
    response = user.daily_responses.create!(daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
      answers: { "code_review" => "x" * 20, "pattern" => "y" * 20 },
      section_ratings: { "code_review" => "right_level", "pattern" => "too_hard" },
      concept_tags: { "code_review" => "n_plus_one", "pattern" => "n_plus_one" },
      ai_review: { "code_review" => { "rating" => "strong" }, "pattern" => { "rating" => "developing" } })
    described_class.record_review!(response, sections: response.concept_tags.keys, apply_session_countdown: true)
    cm = user.concept_masteries.find_by(concept: "n_plus_one", language: "ruby_rails")
    # least-favorable: rep_ai = developing, self not all-favorable → not mastered, baseline records developing
    expect(cm.last_rating).to eq("developing")
    expect(cm.tier).to eq("standard")
  end

  it "buckets a security_review-tagged concept under the exercise's language, not a separate 'architecture'-style bucket" do
    cm = review!(concept: "sql_injection_prevention", self_rating: "too_hard", ai_rating: "developing", section: "security_review")
    expect(cm.language).to eq("ruby_rails")
  end

  it "skips a concept whose representative section was unreviewed" do
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "concept" => "n_plus_one" } })
    response = user.daily_responses.create!(daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
      answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "right_level" },
      concept_tags: { "code_review" => "n_plus_one" }, ai_review: {})
    described_class.record_review!(response, sections: response.concept_tags.keys, apply_session_countdown: true)
    expect(user.concept_masteries.find_by(concept: "n_plus_one")).to be_nil
  end

  # The membership rule has one home so a future selection query cannot filter
  # on `language:` alone and silently reintroduce issue #97 — a row whose
  # concept has left the vocabulary can never resolve, so it would claim a slot
  # forever.
  describe ".in_bucket" do
    def mastery(concept:, bucket:)
      user.concept_masteries.create!(concept: concept, language: bucket, tier: :standard)
    end

    it "keeps a concept still in the bucket's vocabulary" do
      mastery(concept: "memoization", bucket: "ruby_rails")

      expect(user.concept_masteries.in_bucket("ruby_rails").map(&:concept)).to eq(%w[memoization])
    end

    it "drops a concept that has left the bucket's vocabulary" do
      mastery(concept: "retired_concept", bucket: "ruby_rails")

      expect(user.concept_masteries.in_bucket("ruby_rails")).to be_empty
    end

    # Scopes the bucket too, so a concept valid in another bucket's vocabulary
    # cannot qualify here.
    it "drops a row from a different bucket" do
      mastery(concept: "closures", bucket: "javascript")

      expect(user.concept_masteries.in_bucket("ruby_rails")).to be_empty
    end
  end

  describe "retention scheduling" do
    it "schedules the first check 7 days out on initial mastery" do
      cm = review!(concept: "n_plus_one", self_rating: "right_level", ai_rating: "strong")
      expect(cm.mastered_at).to be_present
      expect(cm.retention_interval_days).to eq(7)
      expect(cm.next_retention_check_on).to eq(Date.current + 7)
    end

    it "doubles the interval when the scheduled check was due" do
      cm = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails",
        retention_interval_days: 7, next_retention_check_on: Date.current - 1)
      cm = review!(concept: "n_plus_one", self_rating: "right_level", ai_rating: "strong")
      expect(cm.retention_interval_days).to eq(14)
      expect(cm.next_retention_check_on).to eq(Date.current + 14)
    end

    it "re-anchors the date without growing the interval when the check was not due" do
      cm = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails",
        retention_interval_days: 7, next_retention_check_on: Date.current + 5)
      cm = review!(concept: "n_plus_one", self_rating: "right_level", ai_rating: "strong")
      expect(cm.retention_interval_days).to eq(7)
      expect(cm.next_retention_check_on).to eq(Date.current + 7)
    end

    it "caps the interval at 60 days" do
      cm = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails",
        retention_interval_days: 56, next_retention_check_on: Date.current - 1)
      cm = review!(concept: "n_plus_one", self_rating: "right_level", ai_rating: "strong")
      expect(cm.retention_interval_days).to eq(60)
    end

    it "clears the schedule on a non-mastered evaluation and leaves mastered_at intact" do
      mastered_time = 1.day.ago
      cm = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails",
        mastered_at: mastered_time, retention_interval_days: 7, next_retention_check_on: Date.current + 7)
      cm = review!(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing")
      expect(cm.next_retention_check_on).to be_nil
      expect(cm.retention_interval_days).to be_nil
      expect(cm.mastered_at).to be_present
    end

    it "returns a failed check's concept to normal reinforcement" do
      user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails",
        mastered_at: 1.day.ago, retention_interval_days: 7, next_retention_check_on: Date.current + 7)
      review!(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing")
      expect(user.concepts_needing_reinforcement.map { |r| r[:concept] }).to include("n_plus_one")
    end

    it "anchors the next check on today, not the reviewed response's date, for a late review" do
      cm = review!(concept: "n_plus_one", self_rating: "right_level", ai_rating: "strong", date: Date.current - 10)
      # response.date decides whether the check was due (it was, absent a prior
      # schedule this counts as initial mastery); the NEXT check must still count
      # forward from today, not from the 10-day-old response date, or reviewing
      # a stale submission would schedule a check that's already overdue.
      expect(cm.next_retention_check_on).to eq(Date.current + 7)
    end

    it "keeps mastered_at as the original mastery time across a later successful retention check" do
      cm = review!(concept: "n_plus_one", self_rating: "right_level", ai_rating: "strong", date: Date.current - 20)
      original_mastered_at = cm.mastered_at
      cm.update!(next_retention_check_on: Date.current - 1)

      cm = review!(concept: "n_plus_one", self_rating: "right_level", ai_rating: "strong")

      expect(cm.mastered_at).to eq(original_mastered_at)
    end
  end

  describe ".record_review! — per-section scoping" do
    it "does not evaluate a concept whose section is excluded from sections:" do
      user = User.create!(email: "scope_test@example.com", name: "ST")
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
          "pattern"     => { "title" => "t", "question" => "q", "concept" => "memoization" }
        }
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "a" * 20, "pattern" => "a" * 20 }, submitted_at: Time.current,
        section_ratings: { "code_review" => "right_level", "pattern" => "right_level" },
        concept_tags: { "code_review" => "n_plus_one", "pattern" => "memoization" },
        ai_review: {
          "code_review" => { "rating" => "solid" },
          "pattern"     => { "rating" => "solid" }
        }
      )

      ConceptMastery.record_review!(response, sections: %w[code_review], apply_session_countdown: true)

      expect(user.concept_masteries.find_by(concept: "n_plus_one")).to be_present
      expect(user.concept_masteries.find_by(concept: "memoization")).to be_nil
    end

    it "does not decrement paused concepts' cooldown when apply_session_countdown is false" do
      user = User.create!(email: "countdown_false@example.com", name: "CF")
      paused = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } }
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
        concept_tags: { "code_review" => "n_plus_one" },
        ai_review: { "code_review" => { "rating" => "solid" } }
      )

      ConceptMastery.record_review!(response, sections: %w[code_review], apply_session_countdown: false)

      expect(paused.reload.cooldown_remaining).to eq(2)
    end

    it "decrements paused concepts' cooldown when apply_session_countdown is true" do
      user = User.create!(email: "countdown_true@example.com", name: "CT")
      paused = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } }
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
        concept_tags: { "code_review" => "n_plus_one" },
        ai_review: { "code_review" => { "rating" => "solid" } }
      )

      ConceptMastery.record_review!(response, sections: %w[code_review], apply_session_countdown: true)

      expect(paused.reload.cooldown_remaining).to eq(1)
    end
  end

  describe ".record_review! — unanswered sections" do
    def reviewed_day(answers:, concept_tags:, ai_review:, section_ratings: {})
      exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: concept_tags.transform_values { |concept| { "concept" => concept } })
      user.daily_responses.create!(daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
        answers: answers, section_ratings: section_ratings, concept_tags: concept_tags, ai_review: ai_review)
    end

    it "records nothing for a concept whose only section was skipped" do
      response = reviewed_day(answers: { "code_review" => "" },
                              concept_tags: { "code_review" => "n_plus_one" },
                              ai_review: { "code_review" => { "rating" => "beginner" } })

      described_class.record_review!(response, sections: %w[code_review], apply_session_countdown: true)

      expect(user.concept_masteries.find_by(concept: "n_plus_one")).to be_nil
    end

    it "leaves an existing mastery row untouched when its section was skipped" do
      cm = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails",
                                          tier: :standard, streak: 2, last_rating: "solid")
      response = reviewed_day(answers: { "code_review" => "" },
                              concept_tags: { "code_review" => "n_plus_one" },
                              ai_review: { "code_review" => { "rating" => "beginner" } })

      described_class.record_review!(response, sections: %w[code_review], apply_session_countdown: true)

      expect(cm.reload).to have_attributes(tier: "standard", streak: 2, last_rating: "solid")
    end

    # Before this, a skipped check counted as a failed one: the schedule was
    # wiped and the concept dropped back into reinforcement.
    it "defers a skipped due retention check one unchanged interval without changing knowledge" do
      due_on = Date.current - 1
      mastered_at = 30.days.ago.change(usec: 0)
      cm = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :standard,
                                          streak: 2, last_rating: "strong", mastered_at: mastered_at,
                                          retention_interval_days: 7, next_retention_check_on: due_on)
      response = reviewed_day(answers: { "code_review" => "" },
                              concept_tags: { "code_review" => "n_plus_one" },
                              ai_review: { "code_review" => { "rating" => "beginner" } })

      described_class.record_review!(response, sections: %w[code_review], apply_session_countdown: true)

      expect(cm.reload).to have_attributes(next_retention_check_on: Date.current + 7, retention_interval_days: 7,
        tier: "standard", streak: 2, last_rating: "strong", mastered_at: mastered_at)
    end

    it "does not defer again when a skipped batch is retried after its deferred date" do
      cm = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails",
        retention_interval_days: 7, next_retention_check_on: Date.current)
      response = reviewed_day(answers: {}, concept_tags: { "code_review" => "n_plus_one" },
        ai_review: { "code_review" => { "rating" => "beginner" } })
      described_class.record_review!(response, sections: %w[code_review], apply_session_countdown: false)
      deferred_date = Date.current + 7
      travel_to(20.days.from_now) do
        described_class.record_review!(response, sections: %w[code_review], apply_session_countdown: false)
        expect(cm.reload.next_retention_check_on).to eq(deferred_date)
      end
    end

    it "uses the work date for eligibility and the user's current date for the next check" do
      user.update!(time_zone: "Pacific/Honolulu")
      travel_to(Time.utc(2026, 9, 19, 4)) do
        cm = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails",
          retention_interval_days: 7, next_retention_check_on: Date.new(2026, 9, 10))
        response = reviewed_day(answers: {}, concept_tags: { "code_review" => "n_plus_one" },
          ai_review: { "code_review" => { "rating" => "beginner" } })
        response.update!(date: Date.new(2026, 9, 12))

        described_class.record_review!(response, sections: %w[code_review], apply_session_countdown: false)

        expect(cm.reload.next_retention_check_on).to eq(Date.new(2026, 9, 25))
      end
    end

    it "does not defer a skipped duplicate while its answered section awaits a later batch" do
      cm = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails",
        retention_interval_days: 7, next_retention_check_on: Date.current)
      response = reviewed_day(answers: { "pattern" => "A substantive attempt" },
        concept_tags: { "code_review" => "n_plus_one", "pattern" => "n_plus_one" },
        section_ratings: { "pattern" => "right_level" },
        ai_review: { "code_review" => { "rating" => "beginner" } })

      described_class.record_review!(response, sections: %w[code_review], apply_session_countdown: false)
      expect(cm.reload.next_retention_check_on).to eq(Date.current)
      response.ai_review["pattern"] = { "rating" => "strong" }
      described_class.record_review!(response, sections: %w[pattern], apply_session_countdown: false)
      expect(cm.reload.retention_interval_days).to eq(14)
    end

    it "only defers submitted successfully reviewed active tags in the current batch" do
      tagged = %w[n_plus_one memoization service_objects]
      masteries = tagged.map do |concept|
        user.concept_masteries.create!(concept: concept, language: "ruby_rails",
          retention_interval_days: 7, next_retention_check_on: Date.current)
      end
      response = reviewed_day(answers: {},
        concept_tags: { "code_review" => tagged[0], "pattern" => tagged[1], "challenge" => tagged[2] },
        ai_review: { "code_review" => { "rating" => "beginner" }, "challenge" => { "rating" => "beginner" } })
      response.update!(submitted_at: nil)
      described_class.record_review!(response, sections: %w[code_review pattern], apply_session_countdown: false)
      expect(masteries.map { |cm| cm.reload.next_retention_check_on }).to all(eq(Date.current))

      response.update!(submitted_at: Time.current)
      described_class.record_review!(response, sections: %w[code_review pattern], apply_session_countdown: false)
      expect(masteries.map { |cm| cm.reload.next_retention_check_on }).to eq([ Date.current + 7, Date.current, Date.current ])
    end

    it "leaves not-yet-due, invalid-vocabulary and unscheduled concepts unchanged" do
      cm = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails",
        retention_interval_days: 7, next_retention_check_on: Date.current + 1)
      retired = user.concept_masteries.create!(concept: "retired_concept", language: "ruby_rails",
        retention_interval_days: 7, next_retention_check_on: Date.current)
      response = reviewed_day(answers: {}, concept_tags: { "code_review" => "n_plus_one", "pattern" => "retired_concept" },
        ai_review: { "code_review" => {}, "pattern" => {} })
      before = [ cm.attributes, retired.attributes ]

      described_class.record_review!(response, sections: %w[code_review pattern], apply_session_countdown: false)

      expect([ cm.reload.attributes, retired.reload.attributes ]).to eq(before)
    end

    it "evaluates a concept on its answered section alone when it was also tagged on a skipped one" do
      response = reviewed_day(answers: { "code_review" => "x" * 20, "pattern" => "" },
                              concept_tags: { "code_review" => "n_plus_one", "pattern" => "n_plus_one" },
                              section_ratings: { "code_review" => "right_level" },
                              ai_review: { "code_review" => { "rating" => "strong" },
                                           "pattern"     => { "rating" => "beginner" } })

      described_class.record_review!(response, sections: %w[code_review pattern], apply_session_countdown: true)

      cm = user.concept_masteries.find_by(concept: "n_plus_one", language: "ruby_rails")
      expect(cm.last_rating).to eq("strong")
      expect(cm.mastered_at).to be_present
    end
  end

  describe "difficulty targets" do
    it "never reads KindDifficulty and moves tier the same way for a locked kind" do
      expect(KindDifficulty).not_to receive(:for)
      expect(KindDifficulty).not_to receive(:new)
      user.update!(section_kind_levels: { "code_review" => "principal_engineer" }, locked_section_kinds: [ "code_review" ])

      4.times { |i| review!(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing", date: Date.current - (4 - i)) }

      expect(user.concept_masteries.find_by(concept: "n_plus_one", language: "ruby_rails").tier).to eq("reduced")
      expect(user.concepts_needing_reinforcement).to include(concept: "n_plus_one", tier: "reduced")
    end
  end
end

RSpec.describe ConceptMastery, "drills", type: :model do
  let(:user) { User.create!(email: "cm-drill@example.com", name: "CM") }

  def review!(concept:, self_rating:, ai_rating:, date:)
    exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "concept" => concept } })
    response = user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => self_rating },
      concept_tags: { "code_review" => concept }, ai_review: { "code_review" => { "rating" => ai_rating } })
    described_class.record_review!(response, sections: response.concept_tags.keys, apply_session_countdown: true)
    user.concept_masteries.find_by(concept: concept, language: "ruby_rails")
  end

  before { ConceptDrills.start_group!(user, group: "module_design", bucket: "ruby_rails") }

  it "clears the drill on the same co-favorable rating that marks the concept mastered" do
    cm = review!(concept: "shallow_module", self_rating: "right_level", ai_rating: "solid", date: Date.current)

    expect(cm.tier).to eq("standard")
    expect(cm.drilled_at).to be_nil
    expect(cm.drill_group).to be_nil
  end

  it "keeps the drill while the rating only improves" do
    review!(concept: "shallow_module", self_rating: "too_hard", ai_rating: "beginner", date: Date.current - 1)
    cm = review!(concept: "shallow_module", self_rating: "too_hard", ai_rating: "solid", date: Date.current)

    expect(cm.drilled_at).to be_present
  end

  it "keeps the drill when a favorable AI rating meets an unfavorable self-rating" do
    cm = review!(concept: "shallow_module", self_rating: "too_hard", ai_rating: "strong", date: Date.current)

    expect(cm.drilled_at).to be_present
  end

  it "leaves a drill in place on a concept that reaches the paused tier" do
    6.times { |i| review!(concept: "shallow_module", self_rating: "too_hard", ai_rating: "developing", date: Date.current - (6 - i)) }
    cm = user.concept_masteries.find_by(concept: "shallow_module", language: "ruby_rails")

    expect(cm.tier).to eq("paused")
    expect(cm.drilled_at).to be_present
  end
end

RSpec.describe ConceptMastery, ".in_buckets", type: :model do
  it "is an empty relation for no buckets rather than nil" do
    expect(described_class.in_buckets([]).drilling.to_a).to eq([])
  end
end
