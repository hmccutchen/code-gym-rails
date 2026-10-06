require "rails_helper"

RSpec.describe TrialAllowance, type: :model do
  # Tuesday 2026-10-06, 23:30 in New York: the user's day ends in half an
  # hour, Gemini's Pacific day in three and a half.
  let(:now) { Time.utc(2026, 10, 7, 3, 30) }
  let(:user) { create_trial_user(provider: "gemini", cap: 3, time_zone: "America/New_York", house_key: "AIzaHouse") }

  def write_rows(count, provider:, house_key: true, date: Date.new(2026, 10, 6), created_at: now)
    count.times do
      ApiUsage.create!(user: user, purpose: "duck_thread", provider: provider, house_key: house_key,
                       tokens_in: 1, tokens_out: 1, date: date, created_at: created_at)
    end
  end

  it "lets a call through under the account cap and refuses at it, resetting at the user's midnight" do
    write_rows(2, provider: "gemini")
    expect { described_class.check!(user, provider: GeminiService, now: now) }.not_to raise_error

    write_rows(1, provider: "gemini")
    expect { described_class.check!(user, provider: GeminiService, now: now) }
      .to raise_error(AiService::TrialAllowanceError) { |e| expect(e.retry_after).to eq(30 * 60) }
  end

  it "counts attempts on the user's own day, and only this provider's" do
    write_rows(3, provider: "gemini", date: Date.new(2026, 10, 5), created_at: now - 1.day)
    write_rows(3, provider: "anthropic")

    expect { described_class.check!(user, provider: GeminiService, now: now) }.not_to raise_error
  end

  it "refuses every trial once the house guard is reached, resetting with the provider's quota day" do
    stub_env("HOUSE_GEMINI_DAILY_GUARD" => "2")
    other = create_trial_user(provider: "gemini", email: "other@example.com", house_key: "AIzaHouse")
    2.times do
      ApiUsage.create!(user: other, purpose: "duck_thread", provider: "gemini", house_key: true,
                       tokens_in: 1, tokens_out: 1, date: Date.new(2026, 10, 6), created_at: now - 1.hour)
    end

    expect { described_class.check!(user, provider: GeminiService, now: now) }
      .to raise_error(AiService::TrialAllowanceError) { |e| expect(e.retry_after).to eq(3.5 * 3600) }
  end

  it "ignores own-key calls and the previous quota day for the guard" do
    stub_env("HOUSE_GEMINI_DAILY_GUARD" => "1")
    write_rows(1, provider: "gemini", house_key: false)
    write_rows(1, provider: "gemini", created_at: Time.utc(2026, 10, 6, 6))

    expect { described_class.check!(user, provider: GeminiService, now: now) }.not_to raise_error
  end

  it "applies no cap when the invite sets none and no guard when ENV sets none" do
    open = create_trial_user(provider: "gemini", cap: nil, email: "open@example.com", house_key: "AIzaHouse")
    5.times do
      ApiUsage.create!(user: open, purpose: "duck_thread", provider: "gemini", house_key: true,
                       tokens_in: 1, tokens_out: 1, date: Date.current)
    end

    expect { described_class.check!(open, provider: GeminiService) }.not_to raise_error
  end
end
