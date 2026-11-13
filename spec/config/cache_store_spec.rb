require "rails_helper"

RSpec.describe "config/cache.yml" do
  KNOWN_WINDOWS = {
    "User::LOGIN_RATE_LIMIT_WINDOW" => User::LOGIN_RATE_LIMIT_WINDOW,
    "1.hour" => 1.hour,
    "1.day" => 1.day,
    "EXPIRY" => ConceptReferenceFailures::EXPIRY,
    "REPEAT_WINDOW" => SignInCompletion::REPEAT_WINDOW
  }.freeze

  def max_age = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/cache.yml")).dig("production", "store_options", "max_age")

  def written_windows
    Rails.root.glob("app/**/*.rb").flat_map { |file| File.read(file).scan(/(?:within|expires_in): ([A-Z][\w:]*|\d+\.\w+)/).flatten }.uniq
  end

  it "knows every rate limit and cache expiry the app writes, so a new one is checked against max_age" do
    expect(written_windows - KNOWN_WINDOWS.keys).to eq([])
  end

  it "removes entries, which hold emails, IP addresses and user ids, within two days and after every window that reads them" do
    expect(max_age).to be_between(KNOWN_WINDOWS.values.max.to_i + 1, 2.days.to_i)
  end
end
