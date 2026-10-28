require "rails_helper"

RSpec.describe "The smallest day and the daily pair" do
  it "holds Automatic's floors at the number of daily places, so its smallest day is exactly the pair" do
    expect(SectionCount::FLOOR).to eq(DailyKinds::COUNT)
    expect(CompetencyGate::FLOOR).to eq(DailyKinds::COUNT)
  end

  it "lets a fixed setting go below the pair to a single daily place" do
    expect(User::DAILY_SECTION_COUNTS.min).to eq(DailyKinds::FEWEST)
    expect(DailyKinds::FEWEST).to be < DailyKinds::COUNT
  end
end
