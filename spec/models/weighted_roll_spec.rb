require "rails_helper"

RSpec.describe WeightedRoll do
  def pick(weights, value)
    allow(described_class).to receive(:rand).and_return(value)
    described_class.pick(weights)
  end

  it "returns each key within its band" do
    weights = { a: 0.5, b: 0.3, c: 0.2 }

    expect(pick(weights, 0.0)).to eq(:a)
    expect(pick(weights, 0.49)).to eq(:a)
    expect(pick(weights, 0.5)).to eq(:b)
    expect(pick(weights, 0.79)).to eq(:b)
    expect(pick(weights, 0.999)).to eq(:c)
  end

  # 0.5 + 0.3 sums to 0.7999999999999999, an ulp below the boundary.
  it "is exact at a boundary float addition would miss" do
    expect(pick({ a: 0.5, b: 0.3, c: 0.2 }, 0.8)).to eq(:c)
  end

  it "normalizes weights that do not sum to 1" do
    expect(pick({ a: 3, b: 1 }, 0.7)).to eq(:a)
    expect(pick({ a: 3, b: 1 }, 0.8)).to eq(:b)
  end

  it "falls back to the last key if rand returns 1.0" do
    expect(pick({ a: 0.5, b: 0.5 }, 1.0)).to eq(:b)
  end
end
