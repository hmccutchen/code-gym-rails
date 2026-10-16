require "rails_helper"

RSpec.describe CompetencyGate, "with each day's own pair" do
  let(:default_pair) { %w[code_review design_comparison] }

  def result(kind, ai: "solid", self_rating: "right_level")
    ReviewedSectionResults::Result.new(date: nil, kind: kind, level: "senior", ai_rating: ai, self_rating: self_rating, eased: false)
  end

  def good(kind) = result(kind)
  def poor(kind) = result(kind, ai: "developing")

  def day(*results, daily: default_pair, optional: :none)
    CompetencyGate::Day.new(results: results, optional: optional, daily: daily)
  end

  # Recorded from the gate before days carried a pair; the PR that added this spec holds the recording script.
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
