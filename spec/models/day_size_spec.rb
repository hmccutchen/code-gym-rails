require "rails_helper"

RSpec.describe DaySize do
  include AuthHelpers

  it "keeps every fixed count out of replay and diagnostic evidence" do
    user = create_user_with_key
    expect(CompetencyGate).not_to receive(:for)
    (1..4).each do |count|
      user.daily_section_count = count
      decision = DailyPlan.size_for(user)
      expect(decision).to have_attributes(count: count, reason: :setting)
      expect(decision.diagnostics[:gate]).to be_nil
      expect(decision.brake?).to be(false)
    end
  end

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
