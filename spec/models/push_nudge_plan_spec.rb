require "rails_helper"

RSpec.describe PushNudgePlan do
  def due(level: "ready_and_nudges", hour: 14, submitted: false, last_activity_at: nil)
    described_class.due?(level: level, hour: hour, submitted: submitted, last_activity_at: last_activity_at)
  end

  def production_schedule
    YAML.load_file(Rails.root.join("config/recurring.yml"))
        .fetch("production").fetch("generate_daily_exercises").fetch("schedule")
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

  it "stops once the day is submitted, which is the whole stopping rule" do
    expect(due(submitted: true)).to be(false)
  end

  # A day started and walked away from is exactly what a nudge is for.
  it "still nudges a day that was started long enough ago" do
    expect(due(last_activity_at: (described_class::QUIET_PERIOD + 1.minute).ago)).to be(true)
  end

  it "holds off while the answers are still being saved" do
    expect(due(last_activity_at: 1.minute.ago)).to be(false)
    expect(due(last_activity_at: (described_class::QUIET_PERIOD - 1.minute).ago)).to be(false)
  end

  it "nudges at the quiet period's own edge" do
    expect(due(last_activity_at: described_class::QUIET_PERIOD.ago)).to be(true)
  end

  # No per-day dedupe exists, so the quiet period delays a nudge and never silences the day.
  it "keeps nudging an abandoned day for the rest of the window" do
    abandoned_at = 3.hours.ago

    described_class::NUDGE_HOURS.each do |hour|
      expect(due(hour: hour, last_activity_at: abandoned_at)).to be(true)
    end
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

    # due? is built on possible?, so the cron can use the cheap one as a precheck.
    it "never lets due? through where possible? is false" do
      [ "none", "ready", "ready_and_nudges" ].product((0..23).to_a).each do |level, hour|
        next if described_class.possible?(level: level, hour: hour)

        expect(due(level: level, hour: hour)).to be(false)
      end
    end
  end

  # Shortening the cron fails this: QUIET_PERIOD must cover one whole production tick.
  it "covers one whole tick of the production cron schedule" do
    minute, hour = production_schedule.split

    expect(hour).to eq("*")
    expect(minute).to match(/\A\d+\z/)
    expect(described_class::QUIET_PERIOD).to eq(1.hour)
  end

  it "describes its window for the opt-in label, derived from the constant" do
    Time.use_zone("UTC") do
      expect(described_class.window_description).to eq("1pm–5pm")
    end
  end
end
