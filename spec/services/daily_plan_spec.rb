require "rails_helper"

RSpec.describe DailyPlan do
  let(:user) { User.create!(email: "prompt@example.com", name: "Prompt") }

  describe "THIRD_SECTION_WEIGHTS" do
    it "sums to 1.0 across all four weights" do
      expect(DailyPlan::THIRD_SECTION_WEIGHTS.values.sum).to be_within(0.001).of(1.0)
    end

    it "includes parsons_problem" do
      expect(DailyPlan::THIRD_SECTION_WEIGHTS).to have_key(:parsons_problem)
    end
  end

  describe "#roll_third_section" do
    it "returns :architecture below 0.40, :security_review from 0.40-0.60, :challenge from 0.60-0.80, :parsons_problem from 0.80 up" do
      allow(DailyPlan).to receive(:rand).and_return(0.10)
      expect(DailyPlan.send(:roll_third_section)).to eq(:architecture)

      allow(DailyPlan).to receive(:rand).and_return(0.39)
      expect(DailyPlan.send(:roll_third_section)).to eq(:architecture)

      allow(DailyPlan).to receive(:rand).and_return(0.40)
      expect(DailyPlan.send(:roll_third_section)).to eq(:security_review)

      allow(DailyPlan).to receive(:rand).and_return(0.59)
      expect(DailyPlan.send(:roll_third_section)).to eq(:security_review)

      allow(DailyPlan).to receive(:rand).and_return(0.60)
      expect(DailyPlan.send(:roll_third_section)).to eq(:challenge)

      allow(DailyPlan).to receive(:rand).and_return(0.79)
      expect(DailyPlan.send(:roll_third_section)).to eq(:challenge)

      allow(DailyPlan).to receive(:rand).and_return(0.80)
      expect(DailyPlan.send(:roll_third_section)).to eq(:parsons_problem)

      allow(DailyPlan).to receive(:rand).and_return(0.99)
      expect(DailyPlan.send(:roll_third_section)).to eq(:parsons_problem)
    end
  end

  describe "retention check selection" do
    def mastery(concept:, bucket:, due_on:)
      user.concept_masteries.create!(concept: concept, language: bucket, tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: due_on)
    end

    it "fills only the slots reinforcement did not claim" do
      mastery(concept: "memoization", bucket: "ruby_rails", due_on: Date.current - 2)
      allow(user).to receive(:concepts_needing_reinforcement)
        .and_return([ { concept: "a", tier: "standard" }, { concept: "b", tier: "standard" } ])

      checks = DailyPlan.send(:retention_checks_for, user, "ruby_rails", third: :challenge, slots: 1)
      expect(checks.map(&:concept)).to eq(%w[memoization])
    end

    it "prioritizes a threshold-crossed short-interval concept over a merely-due long-interval one" do
      # "n_plus_one": interval 28, due 20 days ago — due, but not yet overdue by
      # its own interval (would need 28 days past due to cross the threshold).
      user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :standard,
                                     mastered_at: 2.months.ago, retention_interval_days: 28,
                                     next_retention_check_on: Date.current - 20)
      # "memoization": interval 7, due 10 days ago — has crossed its own
      # threshold (10 > 7). Sorting by raw due-date alone would rank n_plus_one
      # first (20 days ago < 10 days ago); sorting by overdue-ratio must not.
      user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 10)

      checks = DailyPlan.send(:retention_checks_for, user, "ruby_rails", third: :challenge, slots: 1)
      expect(checks.map(&:concept)).to eq(%w[memoization])
    end

    it "offers nothing when reinforcement already claims three slots" do
      mastery(concept: "memoization", bucket: "ruby_rails", due_on: Date.current - 2)
      expect(DailyPlan.send(:retention_checks_for, user, "ruby_rails", third: :challenge, slots: 0)).to eq([])
    end

    it "offers architecture-bucket concepts only on architecture days" do
      mastery(concept: "service_boundaries", bucket: "architecture", due_on: Date.current - 2)

      on_challenge = DailyPlan.send(:retention_checks_for, user, "ruby_rails", third: :challenge, slots: 3)
      on_arch      = DailyPlan.send(:retention_checks_for, user, "ruby_rails", third: :architecture, slots: 3)

      expect(on_challenge.map(&:concept)).to eq([])
      expect(on_arch.map(&:concept)).to eq(%w[service_boundaries])
    end

    it "never offers a concept from the other language's bucket" do
      mastery(concept: "closures", bucket: "javascript", due_on: Date.current - 2)
      checks = DailyPlan.send(:retention_checks_for, user, "ruby_rails", third: :challenge, slots: 3)
      expect(checks.map(&:concept)).to eq([])
    end
  end

  describe "established concept selection" do
    def established_mastery(concept:, bucket: "ruby_rails", interval: 14)
      user.concept_masteries.create!(concept: concept, language: bucket, tier: :standard,
                                     mastered_at: 2.months.ago, retention_interval_days: interval,
                                     next_retention_check_on: Date.current + 5)
    end

    it "includes standard-tier concepts past their initial retention interval" do
      established_mastery(concept: "memoization", interval: 14)

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", third: :challenge,
                              reinforcement: [], due_checks: [])
      expect(result.map(&:concept)).to eq(%w[memoization])
    end

    it "excludes concepts still on their initial interval (never survived a retention check)" do
      established_mastery(concept: "memoization", interval: 7)

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", third: :challenge,
                              reinforcement: [], due_checks: [])
      expect(result).to eq([])
    end

    it "excludes concepts already claimed by reinforcement" do
      established_mastery(concept: "memoization", interval: 14)

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", third: :challenge,
                              reinforcement: [ { concept: "memoization", tier: "standard" } ], due_checks: [])
      expect(result).to eq([])
    end

    it "excludes concepts already claimed by today's due retention checks" do
      cm = established_mastery(concept: "memoization", interval: 14)

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", third: :challenge,
                              reinforcement: [], due_checks: [ cm ])
      expect(result).to eq([])
    end

    it "excludes reduced and paused tier concepts" do
      user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :reduced,
                                     retention_interval_days: nil)
      user.concept_masteries.create!(concept: "scope_chaining", language: "ruby_rails", tier: :paused,
                                     retention_interval_days: nil, cooldown_remaining: 2)

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", third: :challenge,
                              reinforcement: [], due_checks: [])
      expect(result).to eq([])
    end

    it "only includes architecture-bucket concepts on architecture days, like retention checks do" do
      established_mastery(concept: "service_boundaries", bucket: "architecture", interval: 14)

      on_challenge = DailyPlan.send(:established_concepts_for, user, "ruby_rails", third: :challenge,
                                    reinforcement: [], due_checks: [])
      on_arch      = DailyPlan.send(:established_concepts_for, user, "ruby_rails", third: :architecture,
                                    reinforcement: [], due_checks: [])

      expect(on_challenge).to eq([])
      expect(on_arch.map(&:concept)).to eq(%w[service_boundaries])
    end
  end

  describe "#for" do
    it "includes established in the returned Result" do
      user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                     mastered_at: 2.months.ago, retention_interval_days: 14,
                                     next_retention_check_on: Date.current + 5)

      result = DailyPlan.for(user, language: "ruby_rails")
      expect(result.established.map(&:concept)).to eq(%w[memoization])
    end
  end

  describe "FOURTH_SECTION_WEIGHTS" do
    it "sums to 1.0 across both weights" do
      expect(DailyPlan::FOURTH_SECTION_WEIGHTS.values.sum).to be_within(0.001).of(1.0)
    end

    it "is a 50/50 split" do
      expect(DailyPlan::FOURTH_SECTION_WEIGHTS.values).to eq([ 0.5, 0.5 ])
    end
  end

  describe "#roll_fourth_section" do
    it "returns :plan_review below 0.5, :ambiguity_hunt from 0.5 up" do
      allow(DailyPlan).to receive(:rand).and_return(0.10)
      expect(DailyPlan.send(:roll_fourth_section)).to eq(:plan_review)

      allow(DailyPlan).to receive(:rand).and_return(0.49)
      expect(DailyPlan.send(:roll_fourth_section)).to eq(:plan_review)

      allow(DailyPlan).to receive(:rand).and_return(0.50)
      expect(DailyPlan.send(:roll_fourth_section)).to eq(:ambiguity_hunt)

      allow(DailyPlan).to receive(:rand).and_return(0.99)
      expect(DailyPlan.send(:roll_fourth_section)).to eq(:ambiguity_hunt)
    end
  end

  describe "fourth-slot retention check selection" do
    it "offers a due plan_review-bucket concept only when the bucket matches" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 2)

      matching    = DailyPlan.send(:retention_checks_for_bucket, user, "plan_review", slots: 1)
      non_matching = DailyPlan.send(:retention_checks_for_bucket, user, "ambiguity_hunt", slots: 1)

      expect(matching.map(&:concept)).to eq(%w[scope_creep])
      expect(non_matching.map(&:concept)).to eq([])
    end

    it "offers nothing when slots is zero" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 2)
      expect(DailyPlan.send(:retention_checks_for_bucket, user, "plan_review", slots: 0)).to eq([])
    end
  end

  describe "fourth-slot established concept selection" do
    it "includes standard-tier concepts past their initial retention interval, in the given bucket" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 2.months.ago, retention_interval_days: 14,
                                     next_retention_check_on: Date.current + 5)

      result = DailyPlan.send(:established_concepts_for_bucket, user, "plan_review",
                              reinforcement: [], due_checks: [])
      expect(result.map(&:concept)).to eq(%w[scope_creep])
    end

    it "excludes concepts already claimed by fourth-slot reinforcement or due checks" do
      cm = user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                          mastered_at: 2.months.ago, retention_interval_days: 14,
                                          next_retention_check_on: Date.current + 5)

      by_reinforcement = DailyPlan.send(:established_concepts_for_bucket, user, "plan_review",
                                        reinforcement: [ { concept: "scope_creep", tier: "standard" } ], due_checks: [])
      by_due_check      = DailyPlan.send(:established_concepts_for_bucket, user, "plan_review",
                                        reinforcement: [], due_checks: [ cm ])

      expect(by_reinforcement).to eq([])
      expect(by_due_check).to eq([])
    end
  end

  describe "#overdue_retention_check_pending_for_bucket?" do
    it "is true only once a due check has crossed its own overdue threshold" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 1)
      expect(DailyPlan.send(:overdue_retention_check_pending_for_bucket?, user, "plan_review")).to be(false)

      user.concept_masteries.find_by(concept: "scope_creep").update!(next_retention_check_on: Date.current - 10)
      expect(DailyPlan.send(:overdue_retention_check_pending_for_bucket?, user, "plan_review")).to be(true)
    end
  end

  describe "#for with the fourth slot" do
    it "always includes a fourth kind, reinforcement, due_checks, and established" do
      result = DailyPlan.for(user, language: "ruby_rails")

      expect(DailyPlan::FOURTH_SECTION_WEIGHTS).to have_key(result.fourth)
      expect(result.fourth_reinforcement).to eq([])
      expect(result.fourth_due_checks).to eq([])
      expect(result.fourth_established).to eq([])
    end

    it "excludes fourth-slot buckets from the 3-slot reinforcement pool" do
      exercise = DailyExercise.create!(user: user, date: Date.current - 1, generated_at: Time.current,
                                       problem_set: { "plan_review" => { "concept" => "scope_creep" } })
      DailyResponse.create!(user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
                            answers: { "plan_review" => "an answer" },
                            section_ratings: { "plan_review" => "too_hard" },
                            concept_tags: { "plan_review" => "scope_creep" },
                            ai_review: { "plan_review" => { "rating" => "developing" } })

      # scope_creep is tagged under the plan_review bucket; pin today's fourth
      # roll to that bucket so the assertion isn't at the mercy of the other
      # 50% of rolls landing on ambiguity_hunt instead.
      allow(DailyPlan).to receive(:roll_fourth_section).and_return(:plan_review)

      result = DailyPlan.for(user, language: "ruby_rails")
      expect(result.reinforcement.map { |h| h[:concept] }).not_to include("scope_creep")
      expect(result.fourth_reinforcement.map { |h| h[:concept] }).to include("scope_creep")
    end

    it "reserves the fourth slot's single slot for retention only once meaningfully overdue" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 1)
      allow(user).to receive(:concepts_needing_reinforcement).and_call_original
      allow(user).to receive(:concepts_needing_reinforcement).with(bucket: "plan_review")
        .and_return([ { concept: "unjustified_constant", tier: "standard" } ])
      allow(DailyPlan).to receive(:roll_fourth_section).and_return(:plan_review)

      result = DailyPlan.for(user, language: "ruby_rails")
      expect(result.fourth_due_checks).to eq([]) # not yet meaningfully overdue

      user.concept_masteries.find_by(concept: "scope_creep").update!(next_retention_check_on: Date.current - 10)
      result = DailyPlan.for(user, language: "ruby_rails")
      expect(result.fourth_due_checks.map(&:concept)).to eq(%w[scope_creep])
    end

    # The fourth section's schema permits exactly one concept, so anything past
    # the first reinforcement entry is a concept the prompt would demand of a
    # section that structurally cannot host it.
    it "caps fourth-slot reinforcement at the slot's single capacity" do
      allow(user).to receive(:concepts_needing_reinforcement).and_call_original
      allow(user).to receive(:concepts_needing_reinforcement).with(bucket: "plan_review")
        .and_return([ { concept: "scope_creep",           tier: "standard" },
                      { concept: "unjustified_constant",  tier: "standard" },
                      { concept: "unflagged_behavior_change", tier: "standard" } ])
      allow(DailyPlan).to receive(:roll_fourth_section).and_return(:plan_review)

      result = DailyPlan.for(user, language: "ruby_rails")

      expect(result.fourth_reinforcement.size).to eq(DailyPlan::FOURTH_SLOT_CAPACITY)
      expect(result.fourth_reinforcement.map { |h| h[:concept] }).to eq(%w[scope_creep])
    end

    it "drops fourth-slot reinforcement entirely when an overdue retention check takes the slot" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 10)
      allow(user).to receive(:concepts_needing_reinforcement).and_call_original
      allow(user).to receive(:concepts_needing_reinforcement).with(bucket: "plan_review")
        .and_return([ { concept: "unjustified_constant", tier: "standard" } ])
      allow(DailyPlan).to receive(:roll_fourth_section).and_return(:plan_review)

      result = DailyPlan.for(user, language: "ruby_rails")

      expect(result.fourth_due_checks.map(&:concept)).to eq(%w[scope_creep])
      expect(result.fourth_reinforcement).to eq([])
    end
  end
end
