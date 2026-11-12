require "rails_helper"

RSpec.describe UnopenedSets do
  let(:today) { Date.new(2026, 11, 12) }

  def set(date, opened: false, saved: false) = described_class::Entry.new(date: date, opened: opened, saved: saved)

  def unopened(*dates) = dates.map { |date| set(date) }

  def pause?(sets) = described_class.pause?(sets, today: today)

  it "pauses after three, and the count is one named constant" do
    expect(described_class::PAUSE_AFTER).to eq(3)
  end

  it "pauses when the last three sets were generated and never opened or saved" do
    expect(pause?(unopened(today - 3, today - 2, today - 1))).to be(true)
  end

  it "does not pause when one of the last three was opened" do
    sets = unopened(today - 3, today - 1) << set(today - 2, opened: true)

    expect(pause?(sets)).to be(false)
  end

  it "does not pause when one of the last three has a saved response, opened or not" do
    sets = unopened(today - 3, today - 2) << set(today - 1, saved: true)

    expect(pause?(sets)).to be(false)
  end

  it "counts a set opened or saved before the last three as outside the run" do
    sets = unopened(today - 3, today - 2, today - 1) << set(today - 4, opened: true, saved: true)

    expect(pause?(sets)).to be(true)
  end

  it "skips a day whose generation failed, which neither counts nor resets" do
    expect(pause?(unopened(today - 4, today - 2, today - 1))).to be(true)
    expect(pause?(unopened(today - 2, today - 1))).to be(false)
  end

  it "skips a weekend or a paused stretch between unopened sets" do
    friday = Date.new(2026, 11, 6)
    monday = Date.new(2026, 11, 9)

    expect(pause?(unopened(friday, monday, monday + 1))).to be(true)
    expect(pause?(unopened(today - 60, today - 30, today - 1))).to be(true)
  end

  it "never pauses an account with fewer than three sets" do
    expect(pause?([])).to be(false)
    expect(pause?(unopened(today - 1))).to be(false)
    expect(pause?(unopened(today - 2, today - 1))).to be(false)
  end

  it "does not count a set whose day has not ended in the user's zone" do
    expect(pause?(unopened(today - 2, today - 1, today))).to be(false)
  end

  it "reads the last three by date, whatever order and however many it is handed" do
    sets = [ set(today - 1), set(today - 9, opened: true), set(today - 3), set(today - 2), set(today - 8, saved: true) ]

    expect(pause?(sets)).to be(true)
    expect(pause?(sets << set(today, opened: true))).to be(false)
  end

  it "reads plain values and no database" do
    queries = []
    counting = ->(*, payload) { queries << payload[:sql] }

    ActiveSupport::Notifications.subscribed(counting, "sql.active_record") { pause?(unopened(today - 3, today - 2, today - 1)) }

    expect(queries).to be_empty
  end
end
