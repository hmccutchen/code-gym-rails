require "rails_helper"

RSpec.describe User, "learning track", type: :model do
  def new_account(**attrs)
    User.create!({ email: "new-#{SecureRandom.hex(3)}@example.com", name: "New", time_zone: "UTC" }.merge(attrs))
  end

  # What the learning track backfill left every account that predates it.
  def old_account
    new_account(learning_track: "none", created_at: 1.year.ago)
  end

  def on_track(levels = LearningTrack.preset_levels, **attrs)
    new_account(learning_track: "junior", section_kind_levels: levels, **attrs)
  end

  describe "track vocabulary and storage" do
    it "keeps joining decisions and target levels in separate closed lists" do
      expect(LearningTrack::VALUES).to eq(%w[junior none])
      expect(LearningTrack::LEVELS).to eq(%w[junior senior])
    end

    it "derives a fresh junior preset from every registered kind" do
      expect(LearningTrack.preset_levels).to eq(ExerciseSection.keys.index_with { "junior" })
      LearningTrack.preset_levels.clear
      expect(LearningTrack.preset_levels.keys).to eq(ExerciseSection.keys)
    end

    it "defaults to no decision and an empty non-null cutoff object" do
      user = new_account.reload
      expect(user.learning_track).to be_nil
      expect(user.track_evidence_cutoffs).to eq({})
      expect(User.columns_hash.fetch("learning_track").default).to be_nil
      expect(User.columns_hash.fetch("learning_track").null).to be true
      expect(User.columns_hash.fetch("track_evidence_cutoffs").null).to be false
    end

    it "validates learning_track against the closed list" do
      user = new_account
      user.learning_track = "senior"
      expect(user).not_to be_valid
      expect(user.errors[:learning_track]).to be_present
    end
  end

  describe "#on_learning_track?" do
    it "is true only for the junior track" do
      expect(on_track.on_learning_track?).to be true
      expect(new_account(learning_track: "none").on_learning_track?).to be false
      expect(new_account.on_learning_track?).to be false
    end
  end

  describe "#first_run?" do
    it "is true with no exercise and no decision" do
      expect(new_account.first_run?).to be true
    end

    it "is false for a backfilled account without querying exercises" do
      user = old_account
      expect(user).not_to receive(:daily_exercises)
      expect(user.first_run?).to be false
    end

    it "is false for an unsaved account" do
      expect(User.new.first_run?).to be false
    end

    it "is false once any exercise exists" do
      user = new_account
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                            problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
      expect(user.first_run?).to be false
      expect(user.learning_track_change_allowed?("junior")).to be false
      expect(user.learning_track_change_allowed?("none")).to be false
    end

    it "is false once a decision is recorded" do
      expect(new_account(learning_track: "none").first_run?).to be false
      expect(on_track.first_run?).to be false
    end
  end

  describe "#learning_track_change_allowed?" do
    it "allows joining and declining on first run" do
      user = new_account
      expect(user.learning_track_change_allowed?("junior")).to be true
      expect(user.learning_track_change_allowed?("none")).to be true
    end

    # "none" is what the backfill stored, so accepting it changes nothing; joining must stay closed.
    it "refuses joining from a backfilled account and accepts its stored none as a no-op" do
      user = old_account
      expect(user.learning_track_change_allowed?("junior")).to be false
      expect(user.learning_track_change_allowed?("none")).to be true
    end

    it "lets a track user leave but not rejoin" do
      user = on_track
      expect(user.learning_track_change_allowed?("junior")).to be false
      expect(user.learning_track_change_allowed?("none")).to be true
      user.update!(learning_track: "none")
      expect(user.learning_track_change_allowed?("junior")).to be false
      expect(user.section_kind_levels).to eq(LearningTrack.preset_levels)
    end

    # A mix save that moves the last junior kind up ends the track without re-rendering Leave.
    it "accepts a repeat leave from a user already off the track" do
      user = on_track
      user.update!(learning_track: "none")
      expect(user.learning_track_change_allowed?("none")).to be true
    end

    it "refuses anything outside the closed list" do
      user = new_account
      expect(user.learning_track_change_allowed?("senior")).to be false
      expect(user.learning_track_change_allowed?(nil)).to be false
    end
  end

  describe "clearing the track" do
    it "clears when no kind keeps a junior target, preserving targets and skill level" do
      user = on_track(skill_level: "junior")
      user.update!(section_kind_levels: ExerciseSection.keys.index_with { "senior" })

      expect(user.reload.learning_track).to eq("none")
      expect(user.section_kind_levels.values.uniq).to eq([ "senior" ])
      expect(user.skill_level).to eq("junior")
    end

    it "clears when every target is removed" do
      user = on_track
      user.update!(section_kind_levels: {})
      expect(user.reload.learning_track).to eq("none")
    end

    it "stays on while any kind is still junior" do
      user = on_track(LearningTrack.preset_levels.merge("pattern" => "senior"))
      expect(user.reload.learning_track).to eq("junior")
    end
  end

  describe "evidence cutoffs on a level change" do
    around { |example| travel_to(Time.utc(2026, 10, 14, 15)) { example.run } }

    it "records a junior cutoff dated today when a kind moves back" do
      user = on_track(LearningTrack.preset_levels.merge("architecture" => "senior"))
      user.update!(section_kind_levels: user.section_kind_levels.merge("architecture" => "junior"))

      expect(user.reload.track_evidence_cutoffs).to eq("architecture" => { "level" => "junior", "through" => "2026-10-14" })
    end

    it "records a senior cutoff dated today when a kind moves up" do
      user = on_track
      user.update!(section_kind_levels: user.section_kind_levels.merge("architecture" => "senior"))

      expect(user.reload.track_evidence_cutoffs).to eq("architecture" => { "level" => "senior", "through" => "2026-10-14" })
    end

    it "records nothing for the joining save" do
      user = new_account(skill_level: "principal_engineer")
      user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)

      expect(user.reload.track_evidence_cutoffs).to eq({})
      expect(user.skill_level).to eq("principal_engineer")
    end

    it "records nothing when joining replaces a hand-set senior target" do
      user = new_account(section_kind_levels: { "architecture" => "senior" })
      user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)

      expect(user.reload.track_evidence_cutoffs).to eq({})
    end

    it "records nothing for a change to or from a level outside the track" do
      user = on_track
      user.update!(section_kind_levels: user.section_kind_levels.merge("pattern" => "principal_engineer"))
      expect(user.reload.track_evidence_cutoffs).to eq({})

      user.update!(section_kind_levels: user.section_kind_levels.merge("pattern" => "junior"))
      expect(user.reload.track_evidence_cutoffs).to eq({})
    end

    it "records nothing when removing a target or setting one for the first time" do
      user = on_track
      user.update!(section_kind_levels: user.section_kind_levels.except("pattern"))
      expect(user.reload.track_evidence_cutoffs).to eq({})

      user.update!(section_kind_levels: user.section_kind_levels.merge("pattern" => "senior"))
      expect(user.reload.track_evidence_cutoffs).to eq({})
    end

    it "records nothing off the track" do
      user = new_account(learning_track: "none", section_kind_levels: { "architecture" => "senior" })
      user.update!(section_kind_levels: { "architecture" => "junior" })

      expect(user.reload.track_evidence_cutoffs).to eq({})
    end

    it "records the last transition before finishing the track" do
      user = on_track({ "architecture" => "junior" })
      user.update!(section_kind_levels: { "architecture" => "senior" })

      expect(user.reload.learning_track).to eq("none")
      expect(user.track_evidence_cutoffs).to eq("architecture" => { "level" => "senior", "through" => "2026-10-14" })
    end

    it "replaces the moved kind's cutoff and preserves other cutoffs" do
      pattern_cutoff = { "level" => "junior", "through" => "2026-10-10" }
      user = on_track(track_evidence_cutoffs: {
        "pattern" => pattern_cutoff,
        "architecture" => { "level" => "junior", "through" => "2026-10-11" }
      })
      user.update!(section_kind_levels: user.section_kind_levels.merge("architecture" => "senior"))

      expect(user.reload.track_evidence_cutoffs).to eq(
        "pattern" => pattern_cutoff,
        "architecture" => { "level" => "senior", "through" => "2026-10-14" }
      )
    end

    it "preserves cutoffs when targets are unchanged" do
      cutoffs = { "pattern" => { "level" => "junior", "through" => "2026-10-10" } }
      user = on_track(track_evidence_cutoffs: cutoffs)
      user.update!(name: "Renamed", section_kind_levels: LearningTrack.preset_levels)

      expect(user.reload.track_evidence_cutoffs).to eq(cutoffs)
    end
  end

  it "dates a cutoff in the user's own zone, whatever zone the caller is in" do
    travel_to(Time.utc(2026, 10, 14, 5)) do
      user = on_track(LearningTrack.preset_levels.merge("architecture" => "senior"), time_zone: "Pacific/Honolulu")

      Time.use_zone("UTC") do
        user.update!(section_kind_levels: user.section_kind_levels.merge("architecture" => "junior"))
      end

      expect(user.reload.track_evidence_cutoffs["architecture"]["through"]).to eq("2026-10-13")
    end
  end
end
