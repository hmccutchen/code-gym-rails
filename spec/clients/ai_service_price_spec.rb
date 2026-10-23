require "rails_helper"

RSpec.describe AiService::Price do
  def price(**rates) = described_class.new(input: 1, output: 2, cache_write: 1.25, cache_read: 0.1, checked_on: Date.new(2026, 10, 6), **rates)

  it "holds each rate as a BigDecimal" do
    expect(price.to_h.except(:checked_on).values).to all(be_a(BigDecimal))
    expect(price.cache_read).to eq(BigDecimal("0.1"))
  end

  it "refuses a missing or negative rate when the table is built, so a bad entry never reaches a call" do
    expect { price(cache_write: nil) }.to raise_error(ArgumentError)
    expect { price(output: -1) }.to raise_error(ArgumentError, /negative/)
  end
end

RSpec.describe AiService, ".cost_usd" do
  it "sums every token kind at the routed Claude model's rates" do
    cost = ClaudeService.cost_usd(model: "claude-opus-5-5", input_tokens: 1_000, output_tokens: 2_000,
                                  cache_read_tokens: 10_000, cache_write_tokens: 3_000)

    expect(cost).to eq(BigDecimal("0.061"))
  end

  it "costs a call with no tokens nothing, and an unpriced Claude model nil" do
    expect(ClaudeService.cost_usd(model: "claude-unpriced", input_tokens: 0, output_tokens: 0)).to eq(0)
    expect(ClaudeService.cost_usd(model: "claude-unpriced", input_tokens: 5, output_tokens: 5)).to be_nil
  end
end
