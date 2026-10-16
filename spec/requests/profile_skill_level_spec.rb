require "rails_helper"

RSpec.describe "PATCH /profile skill_level", type: :request do
  let(:user) { create_user_with_key }
  let(:headers) { { "Content-Type" => "application/json", "Accept" => "application/json" } }

  def patch_profile(user_params)
    patch profile_path, params: { user: user_params }.to_json, headers: headers
  end

  before { login_as(user) }

  User::SKILL_LEVELS.each do |level|
    it "saves #{level}" do
      patch_profile(skill_level: level)

      expect(response).to have_http_status(:ok)
      expect(user.reload.skill_level).to eq(level)
    end
  end

  it "returns the profile fields plus the preference state a track change leaves, for Setup's Exercise mix" do
    patch_profile(skill_level: "senior")

    body = response.parsed_body
    expect(body).to include("name" => "Dev", "time_zone" => "UTC", "daily_section_count" => nil, "kept_own_level" => "")
    expect(body["kind_rungs"]).to eq(user.reload.kind_rungs)
    expect(body["preferences"]).to include("section_kind_levels" => {}, "section_kind_preferences_version" => 0)
  end

  it "leaves the preference version alone when the track change clears no target" do
    expect { patch_profile(skill_level: "principal_engineer") }.not_to(change { user.reload.section_kind_preferences_version })
  end

  [ "expert", "beginner", "developing", "", nil, [ "solid" ], { "level" => "solid" } ].each do |value|
    it "refuses #{value.inspect} without saving anything else in the request" do
      original = user.reload.attributes

      patch_profile(skill_level: value, name: "Not saved")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq("status" => "error", "error" => "Skill level must be one of #{User::SKILL_LEVELS.join(', ')}")
      expect(user.reload.attributes).to eq(original)
    end
  end
end
