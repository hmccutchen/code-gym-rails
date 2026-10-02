require "rails_helper"

RSpec.describe SizeForecast, ".change" do
  def tomorrow(completion:, gate:, reason: :held)
    DaySize.for(setting: nil, completion: completion, gate: CompetencyGate::Plan.new(count: gate, reason: reason, evidence: {}))
  end

  it "is larger when tomorrow's composed size exceeds today's planned size" do
    expect(described_class.change(2, tomorrow(completion: 4, gate: 3, reason: :grew))).to eq(:larger)
  end

  # The gate grew, but completion still holds tomorrow at today's size.
  it "is nothing when completion blocks a gate increase" do
    expect(described_class.change(2, tomorrow(completion: 2, gate: 3, reason: :grew))).to be_nil
  end

  it "is smaller when the brake lowers tomorrow below today's planned size" do
    expect(described_class.change(3, tomorrow(completion: 4, gate: 2, reason: :brake))).to eq(:smaller)
  end

  it "is nothing when tomorrow is smaller for any reason but the brake" do
    expect(described_class.change(3, tomorrow(completion: 2, gate: 4))).to be_nil
    expect(described_class.change(3, tomorrow(completion: 4, gate: 2))).to be_nil
  end

  it "is nothing when the brake is on but the size does not change" do
    expect(described_class.change(2, tomorrow(completion: 4, gate: 2, reason: :brake))).to be_nil
  end
end
