require "rails_helper"

RSpec.describe "PATCH /profile track change", type: :request do
  let(:headers) { { "Content-Type" => "application/json", "Accept" => "application/json" } }
  let(:preset) { ExerciseSection.keys.index_with { "junior" } }
  let(:user) { create_user_with_key }

  around { |example| travel_to(Time.utc(2026, 10, 16, 15)) { example.run } }
  before { login_as(user) }

  def patch_profile(user_params)
    patch profile_path, params: { user: user_params }.to_json, headers: headers
  end

  context "for a junior-preset account with one locked kind and one at senior" do
    before do
      user.update_columns(skill_level: "junior", section_kind_levels: preset.merge("pattern" => "senior"),
                          locked_section_kinds: [ "challenge" ])
    end

    it "leaves no unlocked junior target after the track moves to mid-level in Setup" do
      patch_profile(skill_level: "mid_level")

      expect(response).to have_http_status(:ok)
      levels = user.reload.section_kind_levels
      expect(levels).to eq("challenge" => "junior", "pattern" => "senior")
      expect(levels.except(*user.locked_section_kinds).values).not_to include("junior")
      expect(user.kind_rungs).to include("code_review" => "mid_level", "challenge" => "junior", "pattern" => "senior")
    end

    it "cuts off and records each cleared kind that moved, and nothing for the kinds that kept their level" do
      patch_profile(skill_level: "mid_level")

      cleared = preset.keys - %w[pattern challenge]
      expect(user.reload.level_suggestion_cutoffs.keys).to match_array(cleared)
      expect(user.level_suggestion_events.pluck(:kind, :source).uniq).to match_array(cleared.map { |kind| [ kind, "skill_level_edit" ] })
    end

    it "bumps the preferences version, so another tab's Exercise mix save is refused" do
      stale = user.section_kind_preferences_version

      patch_profile(skill_level: "mid_level")
      patch_profile(section_kind_levels: preset, section_kind_preferences_version: stale)

      expect(response).to have_http_status(:conflict)
      expect(user.reload.section_kind_levels).to eq("challenge" => "junior", "pattern" => "senior")
    end

    it "replies with the saved preferences and names the sections that kept their own level" do
      patch_profile(skill_level: "mid_level")

      body = response.parsed_body
      expect(body.dig("preferences", "section_kind_levels")).to eq("challenge" => "junior", "pattern" => "senior")
      expect(body.dig("preferences", "section_kind_preferences_version")).to eq(user.reload.section_kind_preferences_version)
      expect(body.dig("preferences")).to include("section_kind_weights", "excluded_section_kinds", "locked_section_kinds",
                                                 "ladder_preparation")
      expect(body["kept_own_level"]).to eq(
        I18n.t("tracks.kept_own_level", sections: [
          I18n.t("tracks.kept_section", name: I18n.t("sections.pattern.name"), level: I18n.t("exercise_mix.levels.senior")),
          I18n.t("tracks.kept_locked_section", name: I18n.t("sections.challenge.name"), level: I18n.t("exercise_mix.levels.junior"))
        ].to_sentence)
      )
    end
  end

  it "clears a target equal to the new level without a cutoff or event, since its rung does not move" do
    user.update_columns(skill_level: "junior", section_kind_levels: { "pattern" => "mid_level" })

    patch_profile(skill_level: "mid_level")

    expect(user.reload.section_kind_levels).to eq({})
    expect(user.level_suggestion_cutoffs).not_to have_key("pattern")
    expect(user.level_suggestion_events.where(kind: "pattern")).to be_empty
  end

  it "replies with an empty kept line when every target was cleared" do
    user.update_columns(skill_level: "junior", section_kind_levels: preset)

    patch_profile(skill_level: "senior")

    expect(response.parsed_body["kept_own_level"]).to eq("")
  end
end
