require "rails_helper"

RSpec.describe "The smallest day and the daily pair" do
  it "holds every floor at the number of daily places, so a smallest day is exactly the pair" do
    expect(SectionCount::FLOOR).to eq(DailyKinds::COUNT)
    expect(CompetencyGate::FLOOR).to eq(DailyKinds::COUNT)
    expect(User::DAILY_SECTION_COUNTS.min).to eq(DailyKinds::COUNT)
  end
end
