require "rails_helper"

RSpec.describe ResetClock do
  # 10pm Pacific on Monday 2026-10-05: Google's day ends in two hours.
  let(:failed_at) { Time.utc(2026, 10, 6, 5) }

  it "resets a Gemini daily limit at the next midnight Pacific" do
    reset = described_class.reset_at("daily_limit", provider: "gemini", failed_at: failed_at)

    expect(reset).to eq(Time.utc(2026, 10, 6, 7))
    expect(reset.in_time_zone("America/Los_Angeles").strftime("%F %T")).to eq("2026-10-06 00:00:00")
  end

  it "asks the provider class for the boundary, and gives any other daily limit a day" do
    expect(GeminiService).to receive(:daily_quota_reset_at).with(failed_at).and_call_original
    described_class.reset_at("daily_limit", provider: "gemini", failed_at: failed_at)

    expect(described_class.reset_at("daily_limit", provider: "openai", failed_at: failed_at)).to eq(failed_at + 1.day)
    expect(described_class.reset_at("daily_limit", provider: "unknown", failed_at: failed_at)).to eq(failed_at + 1.day)
    expect(described_class.reset_at("daily_limit", provider: nil, failed_at: failed_at)).to eq(failed_at + 1.day)
  end

  it "lifts a short limit after the wait asked for, and never under a minute" do
    expect(described_class.reset_at("short_rate_limit", provider: "anthropic", failed_at: failed_at, retry_after: 90)).to eq(failed_at + 90)
    expect(described_class.reset_at("short_rate_limit", provider: "anthropic", failed_at: failed_at, retry_after: 5)).to eq(failed_at + 60)
    expect(described_class.reset_at("short_rate_limit", provider: "anthropic", failed_at: failed_at)).to eq(failed_at + 60)
  end

  it "has no reset for the other kinds" do
    %w[bad_key out_of_credit outage timeout other].each do |kind|
      expect(described_class.reset_at(kind, provider: "gemini", failed_at: failed_at)).to be_nil
    end
  end
end
