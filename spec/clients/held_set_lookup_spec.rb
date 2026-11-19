require "rails_helper"

RSpec.describe HeldSetLookup do
  around do |example|
    original = ENV["HELD_SET_LOOKUP"]
    example.run
  ensure
    ENV["HELD_SET_LOOKUP"] = original
  end

  it "is on only when HELD_SET_LOOKUP is exactly 1" do
    ENV["HELD_SET_LOOKUP"] = "1"

    expect(described_class.enabled?).to be(true)
  end

  it "is off for anything else, so a held set stays on its own date" do
    [ nil, "", "0", "true", " 1", "1\n" ].each do |value|
      ENV["HELD_SET_LOOKUP"] = value
      expect(described_class.enabled?).to be(false), "#{value.inspect} turned it on"
    end
  end
end
