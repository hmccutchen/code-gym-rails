require "rails_helper"

RSpec.describe SizeForecast, ".change" do
  def tomorrow(completion:, gate:, reason: :held)
    DaySize.for(setting: nil, completion: completion, gate: CompetencyGate::Plan.new(count: gate, reason: reason, evidence: {}))
  end

  def change(today, tomorrow) = described_class.change(today, tomorrow)

  it "is larger, with tomorrow's count, when tomorrow's composed size exceeds today's" do
    expect(change(2, tomorrow(completion: 4, gate: 3, reason: :grew))).to eq(SizeForecast::Change.new(direction: :larger, count: 3))
  end

  # The gate grew, but completion still holds tomorrow at today's size.
  it "is nothing when completion blocks a gate increase" do
    expect(change(2, tomorrow(completion: 2, gate: 3, reason: :grew))).to be_nil
  end

  it "is smaller, with tomorrow's count, when the brake lowers tomorrow below today" do
    expect(change(3, tomorrow(completion: 4, gate: 2, reason: :brake))).to eq(SizeForecast::Change.new(direction: :smaller, count: 2))
  end

  it "is nothing when tomorrow is smaller for any reason but the brake" do
    expect(change(3, tomorrow(completion: 2, gate: 4))).to be_nil
    expect(change(3, tomorrow(completion: 4, gate: 2))).to be_nil
  end

  it "is nothing when the brake is on but the size does not change" do
    expect(change(2, tomorrow(completion: 4, gate: 2, reason: :brake))).to be_nil
  end
end
