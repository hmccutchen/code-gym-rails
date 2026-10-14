require "rails_helper"

RSpec.describe "Level suggestion paths from before the rename", type: :request do
  let(:json) { { "Content-Type" => "application/json", "Accept" => "application/json" } }
  let(:user) do
    create_user_with_key.tap do |account|
      account.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)
    end
  end

  before { login_as(user) }

  it "answers a dismissal posted to the old path without a redirect" do
    post "/learning_track/dismissal", params: { kinds: [ "code_review" ] }.to_json, headers: json

    expect(response).to have_http_status(:ok)
    expect(user.reload.track_evidence_cutoffs.keys).to eq([ "code_review" ])
  end

  it "counts an answer posted to the old path without a redirect" do
    post "/learning_track/answer", params: {}.to_json, headers: json

    expect(response).to have_http_status(:ok)
    expect(user.reload.track_proposals_answered).to eq(1)
  end
end
