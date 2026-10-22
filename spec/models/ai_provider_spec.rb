require "rails_helper"

RSpec.describe AiProvider do
  it "uses a known provider's own quota day and falls back to the default for an unknown key" do
    failed_at = Time.utc(2026, 10, 14, 15, 0)

    expect(described_class.daily_quota_reset_at("gemini", failed_at)).to eq(GeminiService.daily_quota_reset_at(failed_at))
    expect(described_class.daily_quota_reset_at(:gemini, failed_at)).to eq(GeminiService.daily_quota_reset_at(failed_at))
    expect(described_class.daily_quota_reset_at("nonsense", failed_at)).to eq(failed_at + 1.day)
    expect(described_class.daily_quota_reset_at(nil, failed_at)).to eq(failed_at + 1.day)
  end
end
