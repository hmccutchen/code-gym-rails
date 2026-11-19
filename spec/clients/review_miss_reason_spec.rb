require "rails_helper"

RSpec.describe ReviewMissReason do
  around do |example|
    original = ENV["REVIEW_MISS_REASON"]
    example.run
  ensure
    ENV["REVIEW_MISS_REASON"] = original
  end

  it "is on only when REVIEW_MISS_REASON is exactly 1" do
    ENV["REVIEW_MISS_REASON"] = "1"

    expect(described_class.enabled?).to be(true)
  end

  it "is off for anything else, so the review prompt stays today's" do
    [ nil, "", "0", "true", " 1", "1\n" ].each do |value|
      ENV["REVIEW_MISS_REASON"] = value
      expect(described_class.enabled?).to be(false), "#{value.inspect} turned it on"
    end
  end
end
