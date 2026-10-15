require "rails_helper"

RSpec.describe "Level suggestion paths and keys from before the rename", type: :request do
  let(:json) { { "Content-Type" => "application/json", "Accept" => "application/json" } }
  let(:user) { create_user_with_key }

  before { login_as(user) }

  it "no longer routes the old learning_track paths" do
    post "/learning_track/dismissal", params: { kinds: [ "code_review" ] }.to_json, headers: json
    expect(response).to have_http_status(:not_found)

    post "/learning_track/answer", params: {}.to_json, headers: json
    expect(response).to have_http_status(:not_found)

    expect(user.reload.level_suggestion_cutoffs).to eq({})
    expect(user.level_suggestion_answers).to eq(0)
  end

  it "ignores the switch's old track_suggestions key" do
    patch profile_path, params: { user: { track_suggestions: false } }.to_json, headers: json

    expect(user.reload.level_suggestions).to be(true)
  end

  it "answers the new paths" do
    post level_suggestion_answer_path, params: {}.to_json, headers: json

    expect(response).to have_http_status(:ok)
    expect(level_suggestion_answer_path).to eq("/level_suggestion/answer")
    expect(level_suggestion_dismissal_path).to eq("/level_suggestion/dismissal")
  end
end
