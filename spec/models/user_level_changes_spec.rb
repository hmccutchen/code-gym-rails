require "rails_helper"

RSpec.describe User, "level changes", type: :model do
  let(:user) do
    create_user_with_key(time_zone: "America/Los_Angeles")
      .tap { |account| account.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels) }
  end
  let(:local_today) { Date.new(2026, 10, 13) }

  around { |example| travel_to(Time.utc(2026, 10, 14, 3)) { example.run } }

  def move(changes)
    user.update!(section_kind_levels: user.section_kind_levels.merge(changes))
  end

  def junior_proposal_for(account)
    LevelSuggestion.for(account)&.steps&.map(&:kind)
  end

  describe "cutoffs" do
    it "records the destination rung through the user's own today" do
      move("code_review" => "mid_level")

      expect(user.reload.level_suggestion_cutoffs).to eq(
        "code_review" => { "level" => "mid_level", "through" => local_today.iso8601 }
      )
    end

    it "records an Apply-style save for the one kind it changed" do
      user.update!(level_suggestion_cutoffs: { "pattern" => { "level" => "junior", "through" => "2026-10-01" } })

      move("design_comparison" => "mid_level")

      expect(user.reload.level_suggestion_cutoffs.keys).to contain_exactly("pattern", "design_comparison")
      expect(user.level_suggestion_cutoffs["pattern"]).to eq("level" => "junior", "through" => "2026-10-01")
    end

    it "records nothing when the same target is saved again" do
      user.update!(section_kind_levels: LearningTrack.preset_levels)

      expect(user.reload.level_suggestion_cutoffs).to eq({})
      expect(user.level_suggestion_events).to be_empty
    end

    it "keeps junior results from before a round trip out of junior evidence" do
      reviewed_level_days(user, "code_review", "junior", 5, ending: local_today - 10)
      expect(junior_proposal_for(user.reload)).to eq([ "code_review" ])
      user.update!(level_suggestion_cutoffs: { "code_review" => { "level" => "senior", "through" => "2026-09-01" } })

      move("code_review" => "mid_level")
      travel 1.day
      move("code_review" => "junior")

      expect(user.reload.level_suggestion_cutoffs["code_review"]).to eq(
        "level" => "junior", "through" => (local_today + 1).iso8601
      )
      expect(junior_proposal_for(user)).to be_nil
      summary = LevelSuggestion.summary(kind: "code_review", level: "junior",
                                        results: LevelSuggestion::Evidence.for(user).results,
                                        cutoffs: user.level_suggestion_cutoffs)
      expect(summary.window_size).to eq(0)
    end
    it "records a new cutoff when a kind returns to the ladder from principal engineer" do
      move("code_review" => "mid_level")
      reviewed_level_days(user, "code_review", "mid_level", 5, ending: local_today)
      travel 1.day
      move("code_review" => "principal_engineer")
      travel 1.day
      move("code_review" => "mid_level")

      expect(user.reload.level_suggestion_cutoffs["code_review"]).to eq(
        "level" => "mid_level", "through" => (local_today + 2).iso8601
      )
      summary = LevelSuggestion.summary(kind: "code_review", level: "mid_level",
                                        results: LevelSuggestion::Evidence.for(user).results,
                                        cutoffs: user.level_suggestion_cutoffs)
      expect(summary.window_size).to eq(0)
    end
  end

  describe "cutoffs on an account without targets" do
    let(:user) { create_user_with_key(time_zone: "America/Los_Angeles", learning_track: "none") }

    it "records a target edit at the new rung" do
      move("code_review" => "mid_level")

      expect(user.reload.level_suggestion_cutoffs).to eq(
        "code_review" => { "level" => "mid_level", "through" => local_today.iso8601 }
      )
    end

    it "records a skill level change for every untargeted kind and no targeted one" do
      user.update!(section_kind_levels: { "pattern" => "senior" })
      user.update_column(:level_suggestion_cutoffs, {})

      user.update!(skill_level: "mid_level")

      cutoffs = user.reload.level_suggestion_cutoffs
      expect(cutoffs.keys).to match_array(ExerciseSection.keys - [ "pattern" ])
      expect(cutoffs.values.uniq).to eq([ { "level" => "mid_level", "through" => local_today.iso8601 } ])
    end

    it "records nothing when a target matches the rung the skill level already gave" do
      move("code_review" => "junior")

      expect(user.reload.level_suggestion_cutoffs).to eq({})
    end

    it "records the skill level's rung when a target is cleared" do
      user.update!(section_kind_levels: { "code_review" => "senior" })

      user.update!(section_kind_levels: {})

      expect(user.reload.level_suggestion_cutoffs["code_review"]).to eq(
        "level" => "junior", "through" => local_today.iso8601
      )
    end

    it "records nothing for a skill level change to principal engineer" do
      user.update!(skill_level: "principal_engineer")

      expect(user.reload.level_suggestion_cutoffs).to eq({})
    end

    it "records nothing for the first-run choice that sets the skill level" do
      account = create_user_with_key(learning_track: nil)

      account.update!(learning_track: "none", skill_level: "senior")

      expect(account.reload.level_suggestion_cutoffs).to eq({})
      expect(account.level_suggestion_events).to be_empty
    end
  end

  describe "applied events" do
    it "labels a change matching the step the card showed as the suggestion" do
      reviewed_level_days(user, "code_review", "junior", 5, ending: local_today - 1)
      user.shown_level_suggestions = { "code_review" => "mid_level" }

      move("code_review" => "mid_level")

      expect(user.level_suggestion_events.sole).to have_attributes(
        kind: "code_review", action: "applied", source: "suggestion", from_level: "junior", to_level: "mid_level",
        window_size: 5, favourable: 5, too_hard_latest3: 0, newest_result_on: local_today - 1
      )
    end

    it "labels a change the proposal did not offer as a Setup edit" do
      reviewed_level_days(user, "code_review", "junior", 5, ending: local_today - 1)

      move("code_review" => "senior", "pattern" => "mid_level")

      expect(user.level_suggestion_events.pluck(:kind, :source, :window_size)).to contain_exactly(
        [ "code_review", "setup_edit", 5 ], [ "pattern", "setup_edit", 0 ]
      )
    end

    it "records a reset to Default as a Setup edit to the skill level's rung" do
      user.update_columns(section_kind_levels: user.section_kind_levels.merge("code_review" => "mid_level"))
      reviewed_level_days(user, "code_review", "mid_level", 5, ending: local_today)

      user.update!(section_kind_levels: user.section_kind_levels.except("code_review"))

      expect(user.level_suggestion_events.sole).to have_attributes(
        kind: "code_review", action: "applied", source: "setup_edit", from_level: "mid_level", to_level: "junior",
        window_size: 5
      )
    end

    it "writes nothing when a target matches the rung it already had" do
      user.update!(section_kind_levels: user.section_kind_levels.except("code_review"))
      user.level_suggestion_events.delete_all

      move("code_review" => "junior")

      expect(user.level_suggestion_events).to be_empty
    end

    it "labels each kind a skill level change moved as a skill level edit" do
      user.update!(learning_track: "none", section_kind_levels: { "pattern" => "senior" })
      user.level_suggestion_events.delete_all
      reviewed_level_days(user, "code_review", "junior", 2, ending: local_today - 1)

      user.update!(skill_level: "mid_level")

      rows = user.level_suggestion_events
      expect(rows.pluck(:kind)).to match_array(ExerciseSection.keys - [ "pattern" ])
      expect(rows.pluck(:source, :from_level, :to_level).uniq).to eq([ %w[skill_level_edit junior mid_level] ])
      expect(rows.find_by(kind: "code_review").window_size).to eq(2)
    end

    it "labels each kind by its own cause when one save changes a target and the skill level" do
      user.update!(learning_track: "none", section_kind_levels: {})
      user.level_suggestion_events.delete_all

      user.update!(skill_level: "mid_level", section_kind_levels: { "pattern" => "senior" })

      expect(user.level_suggestion_events.find_by(kind: "pattern").source).to eq("setup_edit")
      expect(user.level_suggestion_events.find_by(kind: "code_review").source).to eq("skill_level_edit")
    end

    it "labels a change that matches a pending proposal a Setup edit when no step was shown" do
      reviewed_level_days(user, "code_review", "junior", 5, ending: local_today - 1)

      move("code_review" => "mid_level")

      expect(user.level_suggestion_events.sole.source).to eq("setup_edit")
    end

    it "writes nothing for the save that joins the track" do
      account = create_user_with_key(learning_track: nil)
      account.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)

      expect(account.level_suggestion_events).to be_empty
    end

    it "writes nothing when Leave changes no level" do
      user.update!(learning_track: "none")

      expect(user.level_suggestion_events).to be_empty
    end

    it "writes the row for the save that ends the track by moving the last kind to senior" do
      user.update!(section_kind_levels: ExerciseSection.keys.index_with { "senior" }.merge("pattern" => "mid_level"))
      user.level_suggestion_events.delete_all

      move("pattern" => "senior")

      expect(user.reload.learning_track).to eq("none")
      expect(user.level_suggestion_events.sole).to have_attributes(kind: "pattern", from_level: "mid_level", to_level: "senior")
    end

    it "rolls back the level change and its cutoff when the row cannot be written" do
      user
      allow(LevelSuggestionEvent).to receive(:applied_rows).and_return([ { kind: "code_review", action: "ignored" } ])

      expect { move("code_review" => "mid_level") }.to raise_error(ActiveRecord::RecordInvalid)

      expect(user.reload.section_kind_levels["code_review"]).to eq("junior")
      expect(user.level_suggestion_cutoffs).to eq({})
      expect(LevelSuggestionEvent.count).to eq(0)
    end

    it "writes nothing when the level save fails validation" do
      expect { move("code_review" => "grandmaster") }.to raise_error(ActiveRecord::RecordInvalid)

      expect(LevelSuggestionEvent.count).to eq(0)
    end
  end

  describe "finishing the track" do
    it "stays on the track when the last junior kind moves to mid-level" do
      user.update!(section_kind_levels: ExerciseSection.keys.index_with { "senior" }.merge("pattern" => "junior"))

      move("pattern" => "mid_level")

      expect(user.reload.learning_track).to eq("junior")
    end

    it "ends the track once every target is senior" do
      user.update!(section_kind_levels: ExerciseSection.keys.index_with { "senior" }.merge("pattern" => "mid_level"))

      move("pattern" => "senior")

      expect(user.reload.learning_track).to eq("none")
    end

    it "counts a principal engineer target as not below senior" do
      user.update!(section_kind_levels: ExerciseSection.keys.index_with { "senior" }.merge("pattern" => "mid_level"))

      move("pattern" => "principal_engineer")

      expect(user.reload.learning_track).to eq("none")
      expect(user.level_suggestion_events.where(kind: "pattern").last).to have_attributes(
        from_level: "mid_level", to_level: "principal_engineer", source: "setup_edit"
      )
    end
  end
end
