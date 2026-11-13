require "rails_helper"

RSpec.describe PrivacyNotice do
  it "reads how long the sign-in cookie lasts from the session store" do
    expire_after = Rails.application.config.session_options.fetch(:expire_after)

    expect(described_class.session_days).to eq(described_class.days_rounded_up(expire_after))
  end

  it "rounds a part day up, so the page never claims less time than the setting" do
    expect(described_class.days_rounded_up(36.hours.to_i)).to eq(2)
    expect(described_class.days_rounded_up(2.days)).to eq(2)
  end

  it "says how long server logs are kept, as whole days" do
    expect(described_class::LOG_DAYS).to be_a(Integer).and(be_positive)
  end

  it "states no backup retention, since database backups are off" do
    expect(described_class.constants).not_to include(:BACKUP_DAYS)
    expect(described_class.facts.keys).not_to include(:backup_days)
  end
end
