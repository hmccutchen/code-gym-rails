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

  # A job outside the user's zone stamps `date` with the server's day, so the
  # count reads when the row was written, in the user's zone.
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
end
