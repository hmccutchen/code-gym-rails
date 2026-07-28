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
    described_class.record_review!(response)
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
    described_class.record_review!(response)
    cm = user.concept_masteries.find_by(concept: "n_plus_one", language: "ruby_rails")
    # least-favorable: rep_ai = developing, self not all-favorable → not mastered, baseline records developing
    expect(cm.last_rating).to eq("developing")
    expect(cm.tier).to eq("standard")
  end

  it "skips a concept whose representative section was unreviewed" do
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "concept" => "n_plus_one" } })
    response = user.daily_responses.create!(daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
      answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "right_level" },
      concept_tags: { "code_review" => "n_plus_one" }, ai_review: {})
    described_class.record_review!(response)
    expect(user.concept_masteries.find_by(concept: "n_plus_one")).to be_nil
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
end
