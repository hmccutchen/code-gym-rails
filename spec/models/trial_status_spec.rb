require "rails_helper"

RSpec.describe TrialStatus, type: :model do
  # Wednesday 2026-10-07, 10am in New York.
  let(:now) { Time.utc(2026, 10, 7, 14) }

  it "counts the days left with today included, in the user's zone, and today's calls against the cap" do
    travel_to(now) do
      user = create_trial_user(provider: "fake", days: 7, cap: 12, time_zone: "America/New_York")
      3.times { ApiUsage.create!(user: user, purpose: "duck_thread", provider: "fake", house_key: true, tokens_in: 1, tokens_out: 1, date: Date.new(2026, 10, 7)) }
      ApiUsage.create!(user: user, purpose: "duck_thread", provider: "fake", house_key: true, tokens_in: 1, tokens_out: 1, date: Date.new(2026, 10, 6))

      status = described_class.for(user, now: now)

      expect(status.ends_on).to eq(Date.new(2026, 10, 13))
      expect(status.days_left).to eq(7)
      expect(status.used).to eq(3)
      expect(status.cap).to eq(12)
      expect(status).to be_active
      expect(status.ended_on).to be_nil

      expect(described_class.for(user, now: Time.utc(2026, 10, 14, 3)).days_left).to eq(1)
      expect(described_class.for(user, now: Time.utc(2026, 10, 14, 5)).days_left).to eq(0)
    end
  end

  it "names the day the trial ended, and no day when the kill switch ended it early" do
    user = create_trial_user(provider: "fake", days: 3)

    travel_to(user.trial_ends_at + 1.hour) do
      status = described_class.for(user)
      expect(status).not_to be_active
      expect(status.ended_on).to eq(user.trial_ends_at.in_time_zone("UTC").to_date)
    end

    stub_env("TRIALS_DISABLED" => "1")
    status = described_class.for(user)
    expect(status).not_to be_active
    expect(status.ended_on).to be_nil
  end
end
