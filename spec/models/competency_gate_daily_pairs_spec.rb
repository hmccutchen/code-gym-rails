require "rails_helper"

RSpec.describe CompetencyGate, "open-loop preserved-input replay" do
  fixture = JSON.parse(Rails.root.join("spec/fixtures/competency_gate/default_pair_histories.json").read)

  fixture.fetch("histories").each do |history|
    it "replays #{history.fetch('name')} including every diagnostic" do
      days = history.fetch("days").map do |recorded|
        date = Date.iso8601(recorded.fetch("date"))
        results = recorded.fetch("results").map do |kind, level, ai, self_rating, eased|
          ReviewedSectionResults::Result.new(date: date, kind: kind, level: level, ai_rating: ai, self_rating: self_rating, eased: eased)
        end
        completion = CompetencyGate::Completion.new(
          state: (recorded["delivered_core"] - recorded["answered_core"]).empty? ? :complete : :incomplete,
          assigned: recorded["assigned"], delivered: recorded["delivered_core"].size, answered: recorded["answered_core"].size,
          too_hard: results.select(&:too_hard?).map(&:kind), ratings_known: true)
        CompetencyGate::Day.new(date: date, results: results, completion: completion, rungs: {})
      end
      expect(JSON.parse(described_class.plans(days, evidence: true).map(&:to_h).to_json)).to eq(history.fetch("plans"))
    end
  end

  it "covers growth, broad overload and ordinary holds across eight unchanged draws" do
    histories = fixture.fetch("histories")
    expect(histories.size).to eq(8)
    expect(histories.map { |history| history["days"].size }).to all(eq(50))
    expect(histories.flat_map { |history| history["plans"].map { |plan| plan["reason"] } }).to include("grew", "brake", "held")
  end
end
