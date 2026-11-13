require "rails_helper"

RSpec.describe PrivacyNotice do
  it "reads how long cache entries live from config/cache.yml" do
    max_age = Rails.application.config_for(:cache).dig(:store_options, :max_age)

    expect(described_class.cache_days).to eq(max_age / 1.day.to_i)
  end

  it "says how long backups and server logs are kept, as whole days, before the page goes out" do
    expect([ described_class::BACKUP_DAYS, described_class::LOG_DAYS ]).to all(be_a(Integer).and(be_positive))
  end
end
