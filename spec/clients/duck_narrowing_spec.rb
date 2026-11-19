require "rails_helper"

RSpec.describe DuckNarrowing do
  around do |example|
    original = ENV["DUCK_NARROWING"]
    example.run
  ensure
    ENV["DUCK_NARROWING"] = original
  end

  it "is on only when DUCK_NARROWING is exactly 1" do
    ENV["DUCK_NARROWING"] = "1"

    expect(described_class.enabled?).to be(true)
  end

  it "is off for anything else, so the duck stays as it is today" do
    [ nil, "", "0", "true", " 1", "1\n" ].each do |value|
      ENV["DUCK_NARROWING"] = value
      expect(described_class.enabled?).to be(false), "#{value.inspect} turned it on"
    end
  end
end
