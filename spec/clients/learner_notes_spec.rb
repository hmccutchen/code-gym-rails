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

  describe ".on_for?" do
    let(:user) { User.new(provider: "fake", api_keys: { "fake" => "fake-key" }, learner_notes_enabled: true) }

    before { ENV["LEARNER_NOTES"] = "1" }

    it "is on with the switch, the account's setting and its own key" do
      expect(described_class.on_for?(user)).to be(true)
    end

    it "is off with the switch unset, the setting off or no key of the account's own" do
      ENV["LEARNER_NOTES"] = nil
      expect(described_class.on_for?(user)).to be(false)

      ENV["LEARNER_NOTES"] = "1"
      expect(described_class.on_for?(user.dup.tap { |copy| copy.learner_notes_enabled = false })).to be(false)
      expect(described_class.on_for?(user.dup.tap { |copy| copy.api_keys = {} })).to be(false)
    end
  end
end
