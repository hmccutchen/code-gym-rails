require "rails_helper"

RSpec.describe ScheduledGeneration do
  def user_in(zone) = User.new(time_zone: zone)

  describe ".due?" do
    let(:pacific) { user_in("America/Los_Angeles") }

    it "is due from the start hour on a weekday in the user's zone" do
      expect(described_class.due?(pacific, at: Time.utc(2026, 7, 13, 15, 0))).to be(true)
      expect(described_class.due?(pacific, at: Time.utc(2026, 7, 13, 23, 30))).to be(true)
    end

    it "is not due before the start hour" do
      expect(described_class.due?(pacific, at: Time.utc(2026, 7, 13, 14, 59))).to be(false)
    end

    it "is not due on a weekend" do
      expect(described_class.due?(pacific, at: Time.utc(2026, 7, 18, 17, 0))).to be(false)
    end

    it "reads the day in the user's zone when it differs from the UTC day" do
      expect(described_class.due?(pacific, at: Time.utc(2026, 7, 18, 3, 0))).to be(true)
      expect(described_class.due?(user_in("Pacific/Auckland"), at: Time.utc(2026, 7, 12, 21, 0))).to be(true)
      expect(described_class.due?(user_in("Pacific/Auckland"), at: Time.utc(2026, 7, 17, 21, 0))).to be(false)
    end

    it "gives the same answer whatever zone the caller is in" do
      answers = %w[UTC Asia/Tokyo].map { |zone| Time.use_zone(zone) { described_class.due?(pacific, at: Time.utc(2026, 7, 13, 14, 59)) } }

      expect(answers).to eq([ false, false ])
    end

    it "defaults to now" do
      travel_to(Time.utc(2026, 7, 13, 15, 0)) { expect(described_class.due?(pacific)).to be(true) }
    end
  end
end
