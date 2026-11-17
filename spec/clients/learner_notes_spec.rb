require "rails_helper"

RSpec.describe LearnerNotes do
  around do |example|
    original = ENV["LEARNER_NOTES"]
    example.run
  ensure
    ENV["LEARNER_NOTES"] = original
  end

  it "is on only when LEARNER_NOTES is exactly 1" do
    ENV["LEARNER_NOTES"] = "1"

    expect(described_class.enabled?).to be(true)
  end

  it "is off for anything else, so every page stays as it is today" do
    [ nil, "", "0", "true", " 1", "1\n" ].each do |value|
      ENV["LEARNER_NOTES"] = value
      expect(described_class.enabled?).to be(false), "#{value.inspect} turned it on"
    end
  end
end
