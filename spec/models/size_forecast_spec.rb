require "rails_helper"

RSpec.describe SizeForecast do
  def tomorrow(count:, reason: :held)
    DaySize.for(setting: nil, gate: CompetencyGate::Plan.new(count: count, reason: reason, safety_hold: false, evidence: {}))
  end

  it "shows a real increase" do
    expect(described_class.change(2, tomorrow(count: 3))).to eq(described_class::Change.new(direction: :larger, count: 3))
  end

  %i[brake completion].each do |reason|
    it "shows an actual #{reason} reduction but no unchanged floor hold" do
      expect(described_class.change(3, tomorrow(count: 2, reason: reason))).to eq(described_class::Change.new(direction: :smaller, count: 2))
      expect(described_class.change(2, tomorrow(count: 2, reason: reason))).to be_nil
    end
  end

  it "does not infer a safety reduction from an ordinary held count" do
    expect(described_class.change(3, tomorrow(count: 2))).to be_nil
  end

  it "compares against actual core delivery and the base assignment, never supplementary work" do
    user = User.new
    exercise = DailyExercise.new(date: Date.current, plan_notes: { "size" => 2, "coverage" => "pattern" },
      problem_set: { "code_review" => { "purpose" => "trap" }, "design_comparison" => {}, "pattern" => {} })
    allow(DailyPlan).to receive(:size_for).with(user, before: Date.tomorrow).and_return(tomorrow(count: 3))
    expect(described_class.for(user, exercise)).to eq(described_class::Change.new(direction: :larger, count: 3))
    exercise.problem_set["code_review"].delete("purpose")
    expect(described_class.for(user, exercise)).to be_nil
  end
end
