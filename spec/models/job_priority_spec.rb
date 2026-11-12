require "rails_helper"

RSpec.describe JobPriority do
  it "runs a click ahead of a bulk press, and a bulk press ahead of a scheduled set" do
    expect(described_class::CLICK).to be < described_class::BULK
    expect(described_class::BULK).to be < described_class::SCHEDULED
  end

  it "names as CLICK the priority a job gets when none is set" do
    [ GenerateDailyExercisesJob, GenerateConceptReferenceJob, GenerateRecognitionGuideJob ].each do |job|
      expect(job.new.priority || 0).to eq(described_class::CLICK)
    end
  end
end
