require "rails_helper"

RSpec.describe ProfileUpdate, "level changes", type: :model do
  let(:user) do
    create_user_with_key(time_zone: "America/Los_Angeles")
      .tap { |account| account.update!(section_kind_levels: ExerciseSection.keys.index_with { "junior" }) }
  end
  let(:local_today) { Date.new(2026, 10, 13) }

  around { |example| travel_to(Time.utc(2026, 10, 14, 3)) { example.run } }

  def save(account = user, steps: nil, **user_params)
    described_class.new(account, ActionController::Parameters.new(user: user_params, level_suggestion_steps: steps)).save
  end

  def move(changes)
    expect(save(section_kind_levels: user.section_kind_levels.merge(changes)).status).to eq(:saved)
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
      save(section_kind_levels: ExerciseSection.keys.index_with { "junior" })

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
    let(:user) { create_user_with_key(time_zone: "America/Los_Angeles") }

    it "records a target edit at the new rung" do
      move("code_review" => "mid_level")

      expect(user.reload.level_suggestion_cutoffs).to eq(
        "code_review" => { "level" => "mid_level", "through" => local_today.iso8601 }
      )
    end

    it "records a skill level change for every untargeted kind and no targeted one" do
      user.update!(section_kind_levels: { "pattern" => "senior" })

      save(skill_level: "mid_level")

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

      save(section_kind_levels: {})

      expect(user.reload.level_suggestion_cutoffs["code_review"]).to eq(
        "level" => "junior", "through" => local_today.iso8601
      )
    end

    it "records nothing for a skill level change to principal engineer" do
      save(skill_level: "principal_engineer")

      expect(user.reload.level_suggestion_cutoffs).to eq({})
    end

    it "keeps results from an earlier stay at the new skill level out of the evidence" do
      reviewed_level_days(user, "code_review", "mid_level", 5, ending: local_today - 10)

      save(skill_level: "mid_level")

      expect(LevelSuggestion.for(user.reload)).to be_nil
    end

    it "records nothing for the first-run choice that sets the skill level" do
      account = create_user_with_key(email: "first@example.com", track_chosen: false)
      account.update!(section_kind_levels: { "pattern" => "junior" })

      expect(save(account, choose_track: true, skill_level: "senior").status).to eq(:saved)

      expect(account.reload.section_kind_levels).to eq("pattern" => "junior")
      expect(account.level_suggestion_cutoffs).to eq({})
      expect(account.level_suggestion_events).to be_empty
    end
  end

  describe "applied events" do
    it "labels a change matching the step the card showed as the suggestion" do
      reviewed_level_days(user, "code_review", "junior", 5, ending: local_today - 1)

      save(section_kind_levels: user.section_kind_levels.merge("code_review" => "mid_level"),
           steps: [ { "kind" => "code_review", "from" => "junior", "to" => "mid_level" } ])

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

      save(section_kind_levels: user.section_kind_levels.except("code_review"))

      expect(user.level_suggestion_events.sole).to have_attributes(
        kind: "code_review", action: "applied", source: "setup_edit", from_level: "mid_level", to_level: "junior",
        window_size: 5
      )
    end

    it "writes nothing when a target matches the rung it already had" do
      user.update!(section_kind_levels: user.section_kind_levels.except("code_review"))

      move("code_review" => "junior")

      expect(user.level_suggestion_events).to be_empty
    end

    it "labels each kind a skill level change moved as a skill level edit" do
      user.update!(section_kind_levels: { "pattern" => "senior" })
      reviewed_level_days(user, "code_review", "junior", 2, ending: local_today - 1)

      save(skill_level: "mid_level")

      rows = user.level_suggestion_events
      expect(rows.pluck(:kind)).to match_array(ExerciseSection.keys - [ "pattern" ])
      expect(rows.pluck(:source, :from_level, :to_level).uniq).to eq([ %w[skill_level_edit junior mid_level] ])
      expect(rows.find_by(kind: "code_review").window_size).to eq(2)
    end

    it "labels a change that matches a pending proposal a Setup edit when no step was shown" do
      reviewed_level_days(user, "code_review", "junior", 5, ending: local_today - 1)

      move("code_review" => "mid_level")

      expect(user.level_suggestion_events.sole.source).to eq("setup_edit")
    end

    it "writes nothing for targets equal to the rung each kind already had" do
      account = create_user_with_key(email: "fresh@example.com", track_chosen: false)

      save(account, section_kind_levels: ExerciseSection.keys.index_with { "junior" })

      expect(account.level_suggestion_events).to be_empty
    end

    it "writes the row for a single kind's move to senior" do
      user.update!(section_kind_levels: ExerciseSection.keys.index_with { "senior" }.merge("pattern" => "mid_level"))

      move("pattern" => "senior")

      expect(user.level_suggestion_events.sole).to have_attributes(kind: "pattern", from_level: "mid_level", to_level: "senior")
    end

    it "rolls back the level change and its cutoff when the row cannot be written" do
      user
      allow(LevelSuggestionEvent).to receive(:applied_rows).and_return([ { kind: "code_review", action: "ignored" } ])

      expect { save(section_kind_levels: user.section_kind_levels.merge("code_review" => "mid_level")) }
        .to raise_error(ActiveRecord::RecordInvalid)

      expect(user.reload.section_kind_levels["code_review"]).to eq("junior")
      expect(user.level_suggestion_cutoffs).to eq({})
      expect(LevelSuggestionEvent.count).to eq(0)
    end

    it "writes nothing when the level save fails validation" do
      outcome = save(section_kind_levels: user.section_kind_levels.merge("code_review" => "grandmaster"))

      expect(outcome.status).to eq(:invalid)
      expect(LevelSuggestionEvent.count).to eq(0)
    end
  end

  it "records a move to principal engineer as a setup edit with no cutoff" do
    move("pattern" => "mid_level")

    move("pattern" => "principal_engineer")

    expect(user.level_suggestion_events.where(kind: "pattern").last).to have_attributes(
      from_level: "mid_level", to_level: "principal_engineer", source: "setup_edit"
    )
    expect(user.reload.level_suggestion_cutoffs["pattern"]).to include("level" => "mid_level")
  end

  describe "a track change" do
    let(:preset) { ExerciseSection.keys.index_with { "junior" } }

    def chosen(**attrs)
      create_user_with_key(email: "chosen@example.com", time_zone: "UTC").tap { |account| account.update!(**attrs) }
    end

    it "clears targets at the old level and bumps the preferences version on a skill-level-only save" do
      account = chosen(skill_level: "junior", section_kind_levels: preset)
      version = account.section_kind_preferences_version

      save(account, skill_level: "mid_level")

      expect(account.reload.section_kind_levels).to eq({})
      expect(account.section_kind_preferences_version).to eq(version + 1)
    end

    it "records a cutoff at the new rung and a skill_level_edit event for each cleared kind that moved" do
      account = chosen(skill_level: "junior", section_kind_levels: { "code_review" => "junior", "pattern" => "mid_level" })

      save(account, skill_level: "mid_level")

      expect(account.reload.level_suggestion_cutoffs).to include(
        "code_review" => { "level" => "mid_level", "through" => "2026-10-14" }
      )
      events = account.level_suggestion_events.where(kind: "code_review")
      expect(events.pluck(:source, :from_level, :to_level)).to eq([ [ "skill_level_edit", "junior", "mid_level" ] ])
      expect(account.level_suggestion_events.where(kind: "pattern")).to be_empty
    end

    it "leaves the version alone when nothing is cleared" do
      account = chosen(skill_level: "junior", section_kind_levels: { "pattern" => "senior" })
      version = account.section_kind_preferences_version

      save(account, skill_level: "mid_level")

      expect(account.reload.section_kind_levels).to eq("pattern" => "senior")
      expect(account.section_kind_preferences_version).to eq(version)
    end

    it "carries nothing from a track change into a later save that does not move the track" do
      account = chosen(skill_level: "junior", section_kind_levels: preset)
      save(account, skill_level: "mid_level")

      expect { save(account, name: "Renamed") }.not_to(change { [ account.reload.level_suggestion_events.count, account.level_suggestion_cutoffs ] })
    end
  end
end
