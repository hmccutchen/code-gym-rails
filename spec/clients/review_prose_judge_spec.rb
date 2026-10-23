require "rails_helper"

RSpec.describe ReviewProseJudge do
  around do |example|
    original = ENV["REVIEW_PROSE_JUDGE"]
    example.run
  ensure
    ENV["REVIEW_PROSE_JUDGE"] = original
  end

  it "is on only when the variable is exactly 1" do
    { nil => false, "0" => false, "true" => false, "1" => true }.each do |value, expected|
      ENV["REVIEW_PROSE_JUDGE"] = value
      expect(described_class.enabled?).to be(expected)
    end
  end
end
