require "rails_helper"

RSpec.describe ApiUsage, type: :model do
  let(:user) { create_user_with_key }

  def row(**attrs)
    described_class.new({ user: user, purpose: "duck_thread", date: Date.current, tokens_in: 0, tokens_out: 0 }.merge(attrs))
  end

  it "accepts only the listed failure codes, and no failure at all" do
    expect(row).to be_valid
    expect(row(failure: "rate_limit")).to be_valid
    expect(row(failure: "slow")).not_to be_valid
  end

  it "counts one account's calls on one of its days per provider, attempts included" do
    described_class.create!(user: user, purpose: "duck_thread", date: Date.current, tokens_in: 1, tokens_out: 1, provider: "gemini")
    described_class.create!(user: user, purpose: "duck_thread", date: Date.current, tokens_in: 0, tokens_out: 0, provider: "gemini", failure: "rate_limit", http_status: 429)
    described_class.create!(user: user, purpose: "duck_thread", date: Date.current - 1, tokens_in: 1, tokens_out: 1, provider: "gemini", created_at: 1.day.ago)
    described_class.create!(user: user, purpose: "duck_thread", date: Date.current, tokens_in: 1, tokens_out: 1, provider: "anthropic")

    expect(described_class.requests_on(user, Date.current, provider: "gemini")).to eq(2)
    expect(described_class.failed.count).to eq(1)
  end

  # A job outside the user's zone stamps `date` with the server's day, so the count reads write time.
  it "counts one account's calls on its own local day by when they were made" do
    user.update!(time_zone: "America/New_York")
    [ Time.utc(2026, 10, 7, 3, 59), Time.utc(2026, 10, 7, 4), Time.utc(2026, 10, 8, 3, 59), Time.utc(2026, 10, 8, 4) ].each do |at|
      described_class.create!(user: user, purpose: "duck_thread", date: at.to_date, tokens_in: 1, tokens_out: 1, provider: "gemini", created_at: at)
    end

    expect(described_class.requests_on(user, Date.new(2026, 10, 7), provider: "gemini")).to eq(2)
  end

  it "counts house-key calls by when they were made" do
    described_class.create!(user: user, purpose: "duck_thread", date: Date.current, tokens_in: 1, tokens_out: 1, provider: "gemini", house_key: true, created_at: Time.utc(2026, 10, 6, 8))
    described_class.create!(user: user, purpose: "duck_thread", date: Date.current, tokens_in: 1, tokens_out: 1, provider: "gemini", house_key: false, created_at: Time.utc(2026, 10, 6, 8))
    described_class.create!(user: user, purpose: "duck_thread", date: Date.current, tokens_in: 1, tokens_out: 1, provider: "gemini", house_key: true, created_at: Time.utc(2026, 10, 7, 8))

    expect(described_class.house_requests_between(provider: "gemini", from: Time.utc(2026, 10, 6, 7), to: Time.utc(2026, 10, 7, 7))).to eq(1)
  end

  describe ".own_key_totals" do
    let(:since) { Time.utc(2026, 10, 1) }

    def usage(**attrs)
      described_class.create!({ user: user, purpose: "duck_thread", date: Date.new(2026, 10, 5), tokens_in: 0, tokens_out: 0,
                                provider: "anthropic", created_at: Time.utc(2026, 10, 5) }.merge(attrs))
    end

    it "totals requests, cost and unpriced requests per provider" do
      usage(cost_usd: "0.5")
      usage(cost_usd: "0.25")
      usage(cost_usd: nil)
      usage(provider: "gemini", cost_usd: nil)

      expect(described_class.own_key_totals(user, since: since)).to eq([
        ApiUsage::ProviderTotal.new(provider: "anthropic", requests: 3, cost_usd: BigDecimal("0.75"), unpriced_requests: 1),
        ApiUsage::ProviderTotal.new(provider: "gemini", requests: 1, cost_usd: nil, unpriced_requests: 1)
      ])
    end

    it "calls a total priced when it has a cost, even $0, and not when the cost is nil" do
      expect(ApiUsage::ProviderTotal.new(provider: "anthropic", requests: 1, cost_usd: BigDecimal("0"), unpriced_requests: 0).priced?).to be(true)
      expect(ApiUsage::ProviderTotal.new(provider: "gemini", requests: 1, cost_usd: nil, unpriced_requests: 1).priced?).to be(false)
    end

    it "counts a timeout's null cost as unpriced and a network error's zero cost as priced" do
      usage(failure: "timeout", cost_usd: nil)
      usage(failure: "network", cost_usd: 0)

      total = described_class.own_key_totals(user, since: since).first
      expect(total.cost_usd).to eq(0)
      expect(total.unpriced_requests).to eq(1)
    end

    it "returns providers in key order, with a row that has no provider last" do
      usage(provider: nil)
      usage(provider: "openai")
      usage(provider: "gemini")
      usage(provider: "anthropic")

      expect(described_class.own_key_totals(user, since: since).map(&:provider)).to eq([ "anthropic", "gemini", "openai", nil ])
    end

    it "counts failed requests, which wrote zero tokens" do
      usage(failure: "rate_limit", http_status: 429)

      expect(described_class.own_key_totals(user, since: since).first.requests).to eq(1)
    end

    it "leaves out house-key calls, earlier calls and other accounts" do
      usage(house_key: true, tokens_in: 1)
      usage(created_at: since - 1.second, tokens_in: 1)
      usage(user: create_user_with_key(email: "other@example.com"), tokens_in: 1)

      expect(described_class.own_key_totals(user, since: since)).to be_empty
    end
  end
end
