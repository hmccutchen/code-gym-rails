require "rails_helper"

RSpec.describe PushNudgePlan do
  def due(level: "ready_and_nudges", hour: 14, started: false, submitted: false)
    described_class.due?(level: level, hour: hour, started: started, submitted: submitted)
  end

  it "nudges an untouched day inside the window" do
    expect(due).to be(true)
  end

  it "stays silent for a level that did not opt into nudges" do
    expect(due(level: "ready")).to be(false)
    expect(due(level: "none")).to be(false)
  end

  it "stays silent outside the window on both sides" do
    expect(due(hour: described_class::NUDGE_HOURS.min - 1)).to be(false)
    expect(due(hour: described_class::NUDGE_HOURS.max + 1)).to be(false)
  end

  it "fires at both edges of the window" do
    expect(due(hour: described_class::NUDGE_HOURS.min)).to be(true)
    expect(due(hour: described_class::NUDGE_HOURS.max)).to be(true)
  end

  it "stops once the day is started, which is the whole stopping rule" do
    expect(due(started: true)).to be(false)
  end

  it "stops once the day is submitted" do
    expect(due(submitted: true)).to be(false)
  end

  it "accepts a symbol level, since the enum reader returns a string" do
    expect(due(level: :ready_and_nudges)).to be(true)
  end

  describe ".possible?" do
    it "answers the level-and-window half without needing a response" do
      expect(described_class.possible?(level: "ready_and_nudges", hour: 14)).to be(true)
      expect(described_class.possible?(level: "ready", hour: 14)).to be(false)
      expect(described_class.possible?(level: "ready_and_nudges", hour: 9)).to be(false)
    end

    # due? is defined in terms of possible?, so the two can never disagree
    # about the level or the window — which is why the cron may use the cheap
    # one as a precheck without restating the rule.
    it "never lets due? through where possible? is false" do
      [ "none", "ready", "ready_and_nudges" ].product((0..23).to_a).each do |level, hour|
        next if described_class.possible?(level: level, hour: hour)

        expect(described_class.due?(level: level, hour: hour, started: false, submitted: false)).to be(false)
      end
    end
  end

  it "describes its window for the opt-in label, derived from the constant" do
    Time.use_zone("UTC") do
      expect(described_class.window_description).to eq("1pm–5pm")
    end
  end
end
