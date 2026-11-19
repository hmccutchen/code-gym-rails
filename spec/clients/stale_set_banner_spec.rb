require "rails_helper"

RSpec.describe StaleSetBanner do
  around do |example|
    original = ENV["STALE_SET_BANNER"]
    example.run
  ensure
    ENV["STALE_SET_BANNER"] = original
  end

  it "is on only when STALE_SET_BANNER is exactly 1" do
    ENV["STALE_SET_BANNER"] = "1"

    expect(described_class.enabled?).to be(true)
  end

  it "is off for anything else, so freshness and every reply stay today's" do
    [ nil, "", "0", "true", " 1", "1\n" ].each do |value|
      ENV["STALE_SET_BANNER"] = value
      expect(described_class.enabled?).to be(false), "#{value.inspect} turned it on"
    end
  end
end
