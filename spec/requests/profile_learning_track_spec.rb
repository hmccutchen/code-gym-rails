require "rails_helper"

RSpec.describe "PATCH /profile learning_track", type: :request do
  let(:headers) { { "Content-Type" => "application/json", "Accept" => "application/json" } }

  def patch_profile(user_params)
    patch profile_path, params: { user: user_params }.to_json, headers: headers
  end

  def new_account
    create_user_with_key(learning_track: nil)
  end

  def expect_track_refused
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("errors" => [ "That learning track change isn't available." ])
  end

  context "on first run" do
    let(:user) { new_account }

    before { login_as(user) }

    it "applies the preset: junior everywhere, unlocked, version bumped, nothing else touched" do
      patch_profile(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels,
                    section_kind_preferences_version: user.section_kind_preferences_version)

      expect(response).to have_http_status(:ok)
      user.reload
      expect(user.learning_track).to eq("junior")
      expect(user.section_kind_levels).to eq(ExerciseSection.keys.index_with { "junior" })
      expect(user.locked_section_kinds).to eq([])
      expect(user.section_kind_preferences_version).to eq(1)
      expect(response.parsed_body["section_kind_preferences_version"]).to eq(1)
      expect(user.skill_level).to eq("developing")
      expect(user.section_kind_weights).to eq({})
      expect(user.excluded_section_kinds).to eq([])
      expect(user.track_evidence_cutoffs).to eq({})
    end

    it "records Experienced as none and changes nothing else" do
      original = user.reload.attributes.except("learning_track", "updated_at")

      patch_profile(learning_track: "none")

      expect(response).to have_http_status(:ok)
      expect(user.reload.learning_track).to eq("none")
      expect(user.attributes.except("learning_track", "updated_at")).to eq(original)
      expect(response.parsed_body).to eq("name" => user.name, "time_zone" => "UTC", "adaptive_set_size" => true)
    end

    it "refuses Junior without levels, saving nothing" do
      original = user.reload.attributes

      patch_profile(learning_track: "junior", name: "Not saved",
                    section_kind_preferences_version: user.section_kind_preferences_version)

      expect_track_refused
      expect(user.reload.attributes).to eq(original)
    end

    [ {}, { "pattern" => "junior" } ].each do |levels|
      it "refuses Junior with incomplete levels #{levels.inspect}, saving nothing" do
        original = user.reload.attributes

        patch_profile(learning_track: "junior", name: "Not saved", section_kind_levels: levels,
                      section_kind_preferences_version: user.section_kind_preferences_version)

        expect_track_refused
        expect(user.reload.attributes).to eq(original)
      end
    end

    it "refuses Junior with a complete but mismatched preset, saving nothing" do
      original = user.reload.attributes

      patch_profile(learning_track: "junior", name: "Not saved",
                    section_kind_levels: LearningTrack.preset_levels.merge("pattern" => "senior"),
                    section_kind_preferences_version: user.section_kind_preferences_version)

      expect_track_refused
      expect(user.reload.attributes).to eq(original)
    end

    [ {}, { section_kind_preferences_version: nil } ].each do |version|
      it "refuses Junior with an absent or null version #{version.inspect}, saving nothing" do
        original = user.reload.attributes

        patch_profile({ learning_track: "junior", name: "Not saved",
                        section_kind_levels: LearningTrack.preset_levels }.merge(version))

        expect_track_refused
        expect(user.reload.attributes).to eq(original)
      end
    end

    [ "senior", "", nil, [], { "value" => "junior" }, true ].each do |value|
      it "refuses an invalid track #{value.inspect} without saving the other fields" do
        original = user.reload.attributes

        patch_profile(learning_track: value, name: "Not saved", section_kind_levels: LearningTrack.preset_levels)

        expect_track_refused
        expect(user.reload.attributes).to eq(original)
      end
    end

    # This write lands after authentication loaded current_user, but before
    # the save's row lock reloads it. Experienced moves no preference version.
    it "refuses Junior when another tab recorded Experienced first" do
      allow_any_instance_of(ProfileController).to receive(:invalid_adaptive_set_size?).and_wrap_original do |original, *args|
        User.find(user.id).update_column(:learning_track, "none")
        original.call(*args)
      end

      patch_profile(learning_track: "junior", name: "Not saved", section_kind_levels: LearningTrack.preset_levels,
                    section_kind_preferences_version: user.section_kind_preferences_version)

      expect_track_refused
      expect(user.reload.learning_track).to eq("none")
      expect(user.name).to eq("Dev")
      expect(user.section_kind_levels).to eq({})
      expect(user.section_kind_preferences_version).to eq(0)
      expect(user.track_evidence_cutoffs).to eq({})
    end

    it "refuses a valid first-run choice with a stale preference version without saving anything" do
      original = user.reload.attributes

      patch_profile(learning_track: "junior", name: "Not saved", section_kind_levels: LearningTrack.preset_levels,
                    section_kind_preferences_version: user.section_kind_preferences_version - 1)

      expect(response).to have_http_status(:conflict)
      expect(user.reload.attributes).to eq(original)
      expect(response.parsed_body.dig("current", "section_kind_preferences_version")).to eq(0)
    end
  end

  context "join guard for an existing account" do
    it "refuses junior from a backfilled account, saving nothing" do
      user = create_user_with_key
      login_as(user)
      original = user.reload.attributes

      patch_profile(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels,
                    section_kind_preferences_version: user.section_kind_preferences_version)

      expect_track_refused
      expect(user.reload.attributes).to eq(original)
    end

    it "refuses junior from a new account that already has an exercise" do
      user = new_account
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                            problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
      login_as(user)
      original = user.reload.attributes

      patch_profile(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels,
                    section_kind_preferences_version: user.section_kind_preferences_version)

      expect_track_refused
      expect(user.reload.attributes).to eq(original)
    end

    it "accepts none from a backfilled account without changing anything" do
      user = create_user_with_key
      login_as(user)
      original = user.reload.attributes.except("updated_at")

      patch_profile(learning_track: "none")

      expect(response).to have_http_status(:ok)
      expect(user.reload.attributes.except("updated_at")).to eq(original)
    end
  end

  context "on the track" do
    let(:user) do
      new_account.tap { |account| account.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels) }
    end

    before { login_as(user) }

    it "leaves the track and keeps the levels" do
      original = user.reload.attributes.except("learning_track", "updated_at")

      patch_profile(learning_track: "none")

      expect(response).to have_http_status(:ok)
      expect(user.reload.learning_track).to eq("none")
      expect(user.section_kind_levels).to eq(LearningTrack.preset_levels)
      expect(user.attributes.except("learning_track", "updated_at")).to eq(original)
    end

    it "answers a Leave after a mix save already ended the track with success and no change" do
      patch_profile(section_kind_levels: ExerciseSection.keys.index_with { "senior" },
                    section_kind_preferences_version: user.reload.section_kind_preferences_version)
      expect(user.reload.learning_track).to eq("none")
      original = user.attributes.except("updated_at")

      patch_profile(learning_track: "none")

      expect(response).to have_http_status(:ok)
      expect(user.reload.attributes.except("updated_at")).to eq(original)
    end

    it "refuses an Apply against a stale version" do
      original = user.reload.attributes

      patch_profile(section_kind_levels: LearningTrack.preset_levels.merge("pattern" => "senior"),
                    section_kind_preferences_version: user.section_kind_preferences_version - 1)

      expect(response).to have_http_status(:conflict)
      expect(user.reload.attributes).to eq(original)
    end

    it "records a forward Apply cutoff in the user's day without leaving the track" do
      travel_to Time.utc(2026, 10, 12, 1) do
        user.update!(time_zone: "America/Los_Angeles")
        login_as(user)
        version = user.section_kind_preferences_version

        patch_profile(section_kind_levels: LearningTrack.preset_levels.merge("pattern" => "senior"),
                      section_kind_preferences_version: version)

        expect(response).to have_http_status(:ok)
        expect(user.reload.learning_track).to eq("junior")
        expect(user.section_kind_levels).to eq(LearningTrack.preset_levels.merge("pattern" => "senior"))
        expect(user.section_kind_preferences_version).to eq(version + 1)
        expect(user.track_evidence_cutoffs).to eq("pattern" => { "level" => "senior", "through" => "2026-10-11" })
      end
    end

    it "clears the track on the last forward Apply and keeps the senior targets" do
      patch_profile(section_kind_levels: ExerciseSection.keys.index_with { "senior" },
                    section_kind_preferences_version: user.section_kind_preferences_version)

      expect(response).to have_http_status(:ok)
      expect(user.reload.learning_track).to eq("none")
      expect(user.section_kind_levels).to eq(ExerciseSection.keys.index_with { "senior" })
      expect(user.track_evidence_cutoffs).to eq(
        ExerciseSection.keys.index_with { { "level" => "senior", "through" => Date.current.iso8601 } }
      )
    end
  end
end
