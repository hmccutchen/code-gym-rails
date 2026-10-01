require "rails_helper"

RSpec.describe ExerciseSection, "learning track lead" do
  it "has exactly one kind that leads the learning track" do
    expect(described_class.all.count(&:leads_learning_track?)).to eq(1)
  end

  it "is the code review, the one kind in every set" do
    expect(described_class.learning_track_lead).to eq(ExerciseSection::CodeReview)
  end

  it "does not lead by default" do
    expect(described_class.leads_learning_track?).to be(false)
  end
end
