require "rails_helper"

RSpec.describe "Level suggestion paths from before the rename", type: :request do
  let(:json) { { "Content-Type" => "application/json", "Accept" => "application/json" } }
  let(:user) do
    create_user_with_key.tap do |account|
      account.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)
    end
  end

  around { |example| travel_to(Time.utc(2026, 10, 14, 15)) { example.run } }

  before { login_as(user) }

  it "routes POST /learning_track/dismissal to the dismissal endpoint, without a redirect" do
    reviewed_level_days(user, "code_review", "junior", 5, ending: Date.current - 1)

    post "/learning_track/dismissal", params: { kinds: [ "code_review" ] }.to_json, headers: json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("dismissed" => [ "code_review" ])
    expect(user.reload.level_suggestion_cutoffs["code_review"]).to include("level" => "junior")
  end

  it "routes POST /learning_track/answer to the answer endpoint, without a redirect" do
    post "/learning_track/answer", params: {}.to_json, headers: json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("answered" => 1)
    expect(user.reload.level_suggestion_answers).to eq(1)
  end

  it "saves the switch's old track_suggestions key under level_suggestions" do
    patch profile_path, params: { user: { track_suggestions: false } }.to_json, headers: json

    expect(response).to have_http_status(:ok)
    expect(user.reload.level_suggestions).to be(false)
  end

  it "refuses an old track_suggestions key that is not true or false" do
    patch profile_path, params: { user: { track_suggestions: "false" } }.to_json, headers: json

    expect(response).to have_http_status(:unprocessable_content)
    expect(user.reload.level_suggestions).to be(true)
  end

  it "answers the new paths the same way" do
    post level_suggestion_answer_path, params: {}.to_json, headers: json

    expect(response).to have_http_status(:ok)
    expect(level_suggestion_answer_path).to eq("/level_suggestion/answer")
    expect(level_suggestion_dismissal_path).to eq("/level_suggestion/dismissal")
  end
end
