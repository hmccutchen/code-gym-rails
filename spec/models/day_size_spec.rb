require "rails_helper"

RSpec.describe DaySize do
  it "keeps coverage held even when the latest transition reason is held" do
    gate = CompetencyGate::Plan.new(count: 2, reason: :held, safety_hold: true, evidence: {})
    decision = described_class.for(setting: nil, gate: gate)
    expect(decision.brake?).to be(true)
    expect(decision.count).to eq(2)
  end

  it "clamps a legacy fixed count" do
    expect(described_class.for(setting: 0).count).to eq(DailyKinds::FEWEST)
    expect(described_class.for(setting: 9).count).to eq(ExerciseSection::MAX_SECTIONS)
  end

  %i[held grew brake completion].each do |reason|
    it "uses the single gate decision for #{reason}" do
      gate = CompetencyGate::Plan.new(count: 3, reason: reason, safety_hold: reason == :brake, evidence: { kinds: {} })
      decision = described_class.for(setting: nil, gate: gate)
      expect(decision.count).to eq(3)
      expect(decision.reason).to eq(%i[brake completion].include?(reason) ? reason : :gate)
      expect(decision.diagnostics[:gate]).to eq(gate.to_h)
    end
  end
end
