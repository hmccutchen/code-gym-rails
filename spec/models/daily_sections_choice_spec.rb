require "rails_helper"

RSpec.describe DailySectionsChoice do
  def kinds(*keys) = keys.map { |key| ExerciseSection.find(key) }

  def choice(stored = [], count: nil) = described_class.new(User.new(daily_section_kinds: stored, daily_section_count: count))

  it "asks for a choice on every setting except Automatic and the pair's own size" do
    expect(choice.counts).to eq(User::DAILY_SECTION_COUNTS.to_a - [ DailyKinds::COUNT ])
    expect(choice.single?(DailyKinds::FEWEST)).to be(true)
    expect(choice.single?(DailyKinds::MOST)).to be(false)
  end

  it "offers the stored pair to keep under a setting of 1, each with the place list that keeping it stores" do
    picked = choice(%w[design_comparison code_review pattern])

    expect(picked.pair).to eq(kinds("design_comparison", "code_review"))
    expect(picked.keeping(ExerciseSection::CodeReview)).to eq(%w[code_review design_comparison pattern])
    expect(picked.keeping(ExerciseSection::DesignComparison)).to eq(%w[design_comparison code_review pattern])
  end

  it "offers every kind the pair leaves room for as an extra section" do
    expect(choice.options).to eq(ExerciseSection.all - DailyKinds::DEFAULT)
    expect(choice(%w[code_review plan_review]).options).to eq(ExerciseSection.all - kinds("code_review", "plan_review") - ExerciseSection.fourths)
  end

  it "preselects the stored extra sections, then fills a new place with the first kind that fits" do
    expect(choice(%w[code_review design_comparison challenge]).extras_for(4)).to eq(kinds("challenge", "pattern"))
    expect(choice.extras_for(3)).to eq(kinds("pattern"))
  end

  it "never preselects a second fourth" do
    picked = choice(%w[code_review design_comparison ambiguity_hunt])
    allow(picked).to receive(:options).and_return(kinds("plan_review", "ambiguity_hunt", "pattern"))

    expect(picked.extras_for(4)).to eq(kinds("ambiguity_hunt", "pattern"))
  end
end
