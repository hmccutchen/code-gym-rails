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

  it "returns the same body other profile saves do" do
    patch_profile(skill_level: "solid")

    expect(response.parsed_body).to eq("name" => "Dev", "time_zone" => "UTC", "adaptive_set_size" => true)
  end

  it "leaves the preference version alone, since skill level is not part of the Exercise mix" do
    expect { patch_profile(skill_level: "strong") }.not_to(change { user.reload.section_kind_preferences_version })
  end

  # A track choice writes only its own fields, so skill level cannot ride along.
  it "is refused when sent with a learning track choice" do
    user.update!(learning_track: nil)
    original = user.reload.attributes

    patch_profile(learning_track: "none", skill_level: "strong")

    expect(response).to have_http_status(:unprocessable_content)
    expect(user.reload.attributes).to eq(original)
  end

  [ "expert", "", nil, [ "solid" ], { "level" => "solid" } ].each do |value|
    it "refuses #{value.inspect} without saving anything else in the request" do
      original = user.reload.attributes

      patch_profile(skill_level: value, name: "Not saved")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq("errors" => [ "Skill level must be one of #{User::SKILL_LEVELS.join(', ')}" ])
      expect(user.reload.attributes).to eq(original)
    end
  end
end
