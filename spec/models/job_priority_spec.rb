require "rails_helper"

RSpec.describe JobPriority do
  it "runs a click ahead of a scheduled set, and a scheduled set ahead of background work" do
    expect(described_class::CLICK).to be < described_class::SCHEDULED
    expect(described_class::SCHEDULED).to be < described_class::BACKGROUND
  end

  it "has no step between a click and a scheduled set, so no press runs ahead of the morning's sets" do
    expect(described_class.constants.sort).to eq(%i[BACKGROUND CLICK SCHEDULED])
  end

  it "names as CLICK the priority a job gets when none is set" do
    [ GenerateDailyExercisesJob, GenerateConceptReferenceJob, GenerateRecognitionGuideJob ].each do |job|
      expect(job.new.priority || 0).to eq(described_class::CLICK)
    end
  end
end
