require "rails_helper"

RSpec.describe "PATCH /profile track choice", type: :request do
  let(:headers) { { "Content-Type" => "application/json", "Accept" => "application/json" } }
  let(:user) { create_user_with_key(track_chosen: false) }

  around { |example| travel_to(Time.utc(2026, 10, 16, 15)) { example.run } }
  before { login_as(user) }

  def patch_profile(user_params)
    patch profile_path, params: { user: user_params }.to_json, headers: headers
  end

  def expect_refused(message)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include("status" => "error", "error" => message)
  end

  LevelSuggestion::LADDER.each do |level|
    it "records a #{level} choice as the skill level with no targets, cutoffs or events" do
      patch_profile(choose_track: true, skill_level: level)

      expect(response).to have_http_status(:ok)
      expect(user.reload).to have_attributes(skill_level: level, track_chosen_at: Time.current, section_kind_levels: {})
      expect(read_learning_track(user)).to be_nil
      expect(user.level_suggestion_cutoffs).to eq({})
      expect(user.level_suggestion_events).to be_empty
      expect(user.first_run?).to be false
    end
  end

  it "refuses principal engineer, which is set by hand in Setup" do
    patch_profile(choose_track: true, skill_level: "principal_engineer")

    expect_refused("That track choice isn't available.")
    expect(user.reload.track_chosen_at).to be_nil
  end

  it "refuses a second choice" do
    patch_profile(choose_track: true, skill_level: "junior")
    patch_profile(choose_track: true, skill_level: "senior")

    expect_refused("That track choice isn't available.")
    expect(user.reload.skill_level).to eq("junior")
  end

  it "refuses a choice carrying other keys, saving nothing" do
    patch_profile(choose_track: true, skill_level: "senior", section_kind_levels: { "pattern" => "junior" })

    expect_refused("That track choice isn't available.")
    expect(user.reload).to have_attributes(track_chosen_at: nil, skill_level: "junior", section_kind_levels: {})
  end

  it "refuses a choice that is not exactly true" do
    patch_profile(choose_track: "yes", skill_level: "senior")

    expect_refused("That track choice isn't available.")
  end

  it "refuses a choice from an account that already has an exercise" do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                          problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })

    patch_profile(choose_track: true, skill_level: "senior")

    expect_refused("That track choice isn't available.")
  end

  it "answers a post from a page rendered before tracks per level with a reload request, saving nothing" do
    patch_profile(learning_track: "junior", section_kind_levels: ExerciseSection.keys.index_with { "junior" },
                  skill_level: "junior", section_kind_preferences_version: 0)

    expect_refused(I18n.t("tracks.stale_page"))
    expect(user.reload).to have_attributes(track_chosen_at: nil, section_kind_levels: {})
  end
end
