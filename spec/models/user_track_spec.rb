require "rails_helper"

RSpec.describe User, "track", type: :model do
  around { |example| travel_to(Time.utc(2026, 10, 16, 15)) { example.run } }

  def new_account(**attrs)
    User.create!({ email: "new-#{SecureRandom.hex(3)}@example.com", name: "New", time_zone: "UTC" }.merge(attrs))
  end

  def chosen(**attrs) = new_account(track_chosen_at: 1.day.ago, learning_track: "none", **attrs)

  describe "#first_run?" do
    it "is true for a saved account with no choice and no exercise" do
      expect(new_account.first_run?).to be true
    end

    it "is false for an unsaved account" do
      expect(User.new.first_run?).to be false
    end

    it "is false once a choice is recorded, without querying exercises" do
      user = chosen
      expect(user).not_to receive(:daily_exercises)
      expect(user.first_run?).to be false
    end

    it "is false for an account that answered the old welcome page before its choice was recorded" do
      user = new_account
      user.update_columns(learning_track: "none")

      expect(user.reload.first_run?).to be false
    end

    it "is false once any exercise exists" do
      user = new_account
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                            problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
      expect(user.first_run?).to be false
    end
  end

  describe "#choose_track" do
    it "records the choice and its level, and writes the old marker for rolled-back code" do
      user = new_account
      user.choose_track("mid_level")
      user.save!

      expect(user.reload).to have_attributes(skill_level: "mid_level", track_chosen_at: Time.current,
                                             learning_track: User::TRACK_CHOICE_MARKER)
      expect(user.first_run?).to be false
    end

    it "keeps a learning_track already written" do
      user = new_account
      user.update_columns(learning_track: "junior")
      user.choose_track("junior")
      user.save!

      expect(user.reload.learning_track).to eq("junior")
    end

    it "records no cutoff and no event for the first choice" do
      user = new_account
      user.choose_track("senior")
      user.save!

      expect(user.reload.level_suggestion_cutoffs).to eq({})
      expect(user.level_suggestion_events).to be_empty
    end
  end

  it "accepts only the legacy learning_track values while they are still written" do
    user = chosen
    user.learning_track = "senior"

    expect(user).not_to be_valid
    expect(user.errors[:learning_track]).to be_present
  end

  describe "a track change" do
    let(:preset) { ExerciseSection.keys.index_with { "junior" } }

    it "clears targets at the old level and bumps the preferences version on a skill-level-only save" do
      user = chosen(skill_level: "junior", section_kind_levels: preset)
      version = user.section_kind_preferences_version

      user.update!(skill_level: "mid_level")

      expect(user.reload.section_kind_levels).to eq({})
      expect(user.section_kind_preferences_version).to eq(version + 1)
    end

    it "records a cutoff at the new rung and a skill_level_edit event for each cleared kind that moved" do
      user = chosen(skill_level: "junior", section_kind_levels: { "code_review" => "junior", "pattern" => "mid_level" })

      user.update!(skill_level: "mid_level")

      expect(user.reload.level_suggestion_cutoffs).to include(
        "code_review" => { "level" => "mid_level", "through" => "2026-10-16" }
      )
      events = user.level_suggestion_events.where(kind: "code_review")
      expect(events.pluck(:source, :from_level, :to_level)).to eq([ [ "skill_level_edit", "junior", "mid_level" ] ])
      expect(user.level_suggestion_events.where(kind: "pattern")).to be_empty
    end

    it "leaves the version alone when nothing is cleared" do
      user = chosen(skill_level: "junior", section_kind_levels: { "pattern" => "senior" })
      version = user.section_kind_preferences_version

      user.update!(skill_level: "mid_level")

      expect(user.reload.section_kind_levels).to eq("pattern" => "senior")
      expect(user.section_kind_preferences_version).to eq(version)
    end

    it "holds no track change on a later save that does not move the track" do
      user = chosen(skill_level: "junior", section_kind_levels: preset)
      user.update!(skill_level: "mid_level")
      user.update!(name: "Renamed")

      expect(user.track_change).to be_nil
    end
  end
end
