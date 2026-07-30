require "rails_helper"

RSpec.describe DailyPlan do
  let(:user) { User.create!(email: "prompt@example.com", name: "Prompt") }

  describe "THIRD_SECTION_WEIGHTS" do
    it "sums to 1.0 across all three weights, including the unused :challenge entry" do
      expect(DailyPlan::THIRD_SECTION_WEIGHTS.values.sum).to be_within(0.001).of(1.0)
    end
  end

  describe "#roll_third_section" do
    it "returns :architecture below 0.50, :security_review from 0.50 up to 0.75, :challenge from 0.75 up" do
      allow(DailyPlan).to receive(:rand).and_return(0.10)
      expect(DailyPlan.send(:roll_third_section)).to eq(:architecture)

      allow(DailyPlan).to receive(:rand).and_return(0.49)
      expect(DailyPlan.send(:roll_third_section)).to eq(:architecture)

      allow(DailyPlan).to receive(:rand).and_return(0.50)
      expect(DailyPlan.send(:roll_third_section)).to eq(:security_review)

      allow(DailyPlan).to receive(:rand).and_return(0.74)
      expect(DailyPlan.send(:roll_third_section)).to eq(:security_review)

      allow(DailyPlan).to receive(:rand).and_return(0.75)
      expect(DailyPlan.send(:roll_third_section)).to eq(:challenge)

      allow(DailyPlan).to receive(:rand).and_return(0.99)
      expect(DailyPlan.send(:roll_third_section)).to eq(:challenge)
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
end
