require "rails_helper"

RSpec.describe ReviewApproachParagraph do
  around do |example|
    original = ENV["REVIEW_APPROACH_PARAGRAPH"]
    example.run
  ensure
    ENV["REVIEW_APPROACH_PARAGRAPH"] = original
  end

  it "is on only when REVIEW_APPROACH_PARAGRAPH is exactly 1" do
    ENV["REVIEW_APPROACH_PARAGRAPH"] = "1"

    expect(described_class.enabled?).to be(true)
  end

  it "is off for anything else, so the review prompt stays today's" do
    [ nil, "", "0", "true", " 1", "1\n" ].each do |value|
      ENV["REVIEW_APPROACH_PARAGRAPH"] = value
      expect(described_class.enabled?).to be(false), "#{value.inspect} turned it on"
    end
  end
end
