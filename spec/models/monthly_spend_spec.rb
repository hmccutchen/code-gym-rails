require "rails_helper"

RSpec.describe MonthlySpend do
  let(:total_class) do
    Data.define(:provider, :requests, :cost_usd, :unpriced_requests) do
      def priced? = !cost_usd.nil?
    end
  end

  def priced(cost, provider: "anthropic", unpriced: 0) = total_class.new(provider:, requests: 1 + unpriced, cost_usd: BigDecimal(cost.to_s), unpriced_requests: unpriced)
  def unpriced(count, provider: "gemini") = total_class.new(provider:, requests: count, cost_usd: nil, unpriced_requests: count)
  def spend(*totals, on: Date.new(2026, 10, 23), paused: false) = described_class.new(totals: totals, today: on, paused: paused)

  it "sums the priced providers and skips unpriced ones" do
    result = spend(priced("4.00"), unpriced(2), priced("0.12", provider: "openai"))

    expect(result.total).to eq(BigDecimal("4.12"))
    expect(result.priced?).to be(true)
  end

  it "has no total when nothing is priced" do
    result = spend(unpriced(3))

    expect(result.total).to be_nil
    expect(result.priced?).to be(false)
    expect(result.projected).to be_nil
  end

  it "counts a $0 row as priced" do
    result = spend(priced("0"))

    expect(result.priced?).to be(true)
    expect(result.total).to eq(0)
  end

  it "projects by weekdays: spend ÷ weekdays elapsed × weekdays in the month" do
    expect(spend(priced("4.12")).projected.round(2)).to eq(BigDecimal("5.33"))
  end

  it "hides the projection while generation is paused" do
    result = described_class.new(totals: [ priced("4.12") ], today: Date.new(2026, 10, 23), paused: true)

    expect(result.projected).to be_nil
    expect(result.total).to eq(BigDecimal("4.12"))
  end

  it "hides the projection when any provider has no priced rows" do
    result = spend(priced("1.20"), unpriced(3))

    expect(result.projected).to be_nil
    expect(result.total).to eq(BigDecimal("1.20"))
  end

  it "still projects a partly priced provider" do
    expect(spend(priced("4.12", unpriced: 2)).projected.round(2)).to eq(BigDecimal("5.33"))
  end

  it "hides the projection on the 1st to the 3rd" do
    (1..3).each do |day|
      expect(spend(priced("4.12"), on: Date.new(2026, 10, day)).projected).to be_nil
    end
    expect(spend(priced("4.12"), on: Date.new(2026, 10, 4)).projected).not_to be_nil
  end

  it "has a weekday behind it by the 4th whatever weekday the month starts on" do
    expect((1..12).map { |m| Date.new(2026, m, 1).wday }.uniq.size).to eq(7)

    (1..12).each do |month|
      projected = spend(priced("1"), on: Date.new(2026, month, 4)).projected
      expect(projected).to be_positive
      expect(projected).to be_finite
    end
  end

  it "gives a weekend day the same projection as the Friday before it" do
    friday = spend(priced("4.12"), on: Date.new(2026, 10, 23)).projected
    saturday = spend(priced("4.12"), on: Date.new(2026, 10, 24)).projected

    expect(saturday).to eq(friday)
  end

  it "counts unpriced requests across providers, including a partly priced one" do
    result = spend(priced("1", unpriced: 1), unpriced(2))

    expect(result.unpriced_requests).to eq(3)
    expect(result.show_unpriced_note?).to be(true)
  end

  it "shows no unpriced note when nothing is priced, or when everything is" do
    expect(spend(unpriced(2)).show_unpriced_note?).to be(false)
    expect(spend(priced("1")).show_unpriced_note?).to be(false)
  end
end
