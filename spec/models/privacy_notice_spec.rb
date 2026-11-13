require "rails_helper"

RSpec.describe PrivacyNotice do
  it "reads how long cache entries live from config/cache.yml" do
    max_age = Rails.application.config_for(:cache).dig(:store_options, :max_age)

    expect(described_class.cache_days).to eq(described_class.days_rounded_up(max_age))
  end

  it "reads how long the sign-in cookie lasts from the session store" do
    expire_after = Rails.application.config.session_options.fetch(:expire_after)

    expect(described_class.session_days).to eq(described_class.days_rounded_up(expire_after))
  end

  it "rounds a part day up, so the page never claims less time than the setting" do
    expect(described_class.days_rounded_up(36.hours.to_i)).to eq(2)
    expect(described_class.days_rounded_up(2.days)).to eq(2)
  end

  it "reads config/cache.yml once, not on every request" do
    described_class.cache_days
    allow(Rails.application).to receive(:config_for).and_call_original

    described_class.cache_days

    expect(Rails.application).not_to have_received(:config_for)
  end

  it "says how long backups and server logs are kept, as whole days, before the page goes out" do
    expect([ described_class::BACKUP_DAYS, described_class::LOG_DAYS ]).to all(be_a(Integer).and(be_positive))
  end
end
