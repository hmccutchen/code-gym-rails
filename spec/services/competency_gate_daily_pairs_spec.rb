require "rails_helper"

RSpec.describe CompetencyGate, "with each day's own pair" do
  let(:default_pair) { %w[code_review design_comparison] }

  def result(kind, ai: "solid", self_rating: "right_level", level: "senior")
    ReviewedSectionResults::Result.new(date: nil, kind: kind, level: level, ai_rating: ai, self_rating: self_rating, eased: false)
  end

  def good(kind, level: "senior") = result(kind, level: level)
  def poor(kind) = result(kind, ai: "developing")
  def too_hard(kind) = result(kind, self_rating: "too_hard")

  def day(*results, daily: default_pair, optional: :none)
    CompetencyGate::Day.new(results: results, optional: optional, daily: daily)
  end

  # Recorded from the gate before days carried a pair by script/record_competency_gate_fixture.rb; see competency-gate.md.
  describe "a history that only ever held the default pair" do
    fixture = JSON.parse(Rails.root.join("spec/fixtures/competency_gate/default_pair_histories.json").read)

    fixture.fetch("histories").each do |history|
      it "plans #{history.fetch('name')} exactly as before, counts, reasons and evidence included" do
        days = history.fetch("days").map do |recorded|
          results = recorded.fetch("results").map do |kind, level, ai, self_rating, eased|
            ReviewedSectionResults::Result.new(date: nil, kind: kind, level: level, ai_rating: ai, self_rating: self_rating, eased: eased)
          end
          day(*results, optional: recorded.fetch("optional").to_sym)
        end

        expect(JSON.parse(described_class.plans(days, evidence: true).map(&:to_h).to_json)).to eq(history.fetch("plans"))
      end
    end

    it "covers accounts that grow, brake and hold" do
      reasons = fixture.fetch("histories").flat_map { |history| history.fetch("plans").map { |plan| plan.fetch("reason") } }

      expect(reasons).to include("grew", "brake", "held")
    end
  end

  describe "a pair that changes partway" do
    let(:swapped) { %w[pattern challenge] }
    let(:earned_three) { Array.new(5) { day(good("code_review")) } }

    it "keeps a size earned under the old pair" do
      after_swap = Array.new(3) { day(good("pattern"), poor("code_review"), daily: swapped) }

      expect(described_class.plans(earned_three + after_swap).map(&:count).last(4)).to eq([ 3, 3, 3, 3 ])
    end

    it "keeps earlier days' results as they were classified, and counts a kind only on days it was daily" do
      after_swap = [ day(good("pattern"), poor("code_review"), daily: swapped) ]

      window = described_class.plan(earned_three + after_swap).evidence.fetch(:to_four)

      expect(window).to include(available: 6, favourable: 6, by_kind: { "code_review" => 5, "pattern" => 1 })
    end

    it "grows from the new pair's results, never from a kind that has become optional" do
      held_by_optional = Array.new(5) { day(poor("pattern"), good("code_review"), good("design_comparison"), daily: swapped) }
      grown_by_daily   = Array.new(3) { day(good("pattern"), good("challenge"), poor("code_review"), daily: swapped) }

      expect(described_class.plans(held_by_optional).map(&:count)).to all(eq(2))
      expect(described_class.plans(grown_by_daily).map(&:count).last).to eq(3)
    end

    it "drops a kind's daily results when a level change reaches it on a day it was optional" do
      first_daily = Array.new(3) { day(good("pattern"), good("challenge"), daily: swapped) }
      optional    = [ day(good("code_review"), good("pattern", level: "junior")) ]
      daily_again = [ day(good("pattern", level: "junior"), good("challenge"), daily: swapped) ]

      window = described_class.plan(first_daily + optional + daily_again).evidence.fetch(:to_four)

      expect(window.fetch(:by_kind)).to eq("challenge" => 4, "pattern" => 1, "code_review" => 1)
    end

    it "brakes on a swapped-out kind's too-hard results, and the brake empties the new pair's growth" do
      after_swap = Array.new(2) { day(good("pattern"), good("challenge"), too_hard("code_review"), daily: swapped) }

      plan = described_class.plan(earned_three + after_swap)

      expect(plan).to have_attributes(count: 2, reason: :brake)
      expect(plan.evidence.fetch(:to_three)).to include(available: 0)
    end

    it "refuses a day whose pair is not a list of section keys" do
      expect { day(good("code_review"), daily: nil) }.to raise_error(ArgumentError, /daily must be a list/)
      expect { day(good("code_review"), daily: [ ExerciseSection::CodeReview ]) }.to raise_error(ArgumentError)
    end
  end

  # Pins today's behaviour for docs/superpowers/specs/2026-10-16-two-section-gate-hold-note.md; a change here is a product decision.
  describe "a two-section day where one daily kind is never favourable" do
    let(:held) { Array.new(10) { day(good("code_review"), poor("design_comparison")) } }

    it "stays at two for as long as that kind stays hard" do
      expect(described_class.plans(held).map(&:count)).to all(eq(2))
    end

    it "grows within three answered days of that kind becoming favourable" do
      recovered = Array.new(3) { day(good("code_review"), good("design_comparison")) }

      counts = described_class.plans(held + recovered).map(&:count).last(3)

      expect(counts.last).to eq(3)
      expect(counts.index(3)).to be < 3
    end
  end
end
