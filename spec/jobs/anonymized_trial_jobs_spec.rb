require "rails_helper"

# A queued job still loads a deleted trial's row by id, so it must not reach the house key.
RSpec.describe "Jobs queued for a deleted trial account", type: :job do
  let(:user) { create_trial_user(provider: "fake") }

  before { user.anonymize! }

  it "makes no call for a concept reference" do
    expect {
      GenerateConceptReferenceJob.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
    }.not_to change(ApiUsage, :count)
    expect(ConceptReference.where(concept: "n_plus_one")).to be_empty
  end

  it "makes no call for a recognition guide" do
    group_key = RecognitionGuide::GROUP_KEYS.first

    expect {
      GenerateRecognitionGuideJob.perform_now(group_key: group_key, user_id: user.id)
    }.not_to change(ApiUsage, :count)
    expect(RecognitionGuide.where(group_key: group_key)).to be_empty
  end
end
