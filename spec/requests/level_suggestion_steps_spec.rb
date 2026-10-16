require "rails_helper"

RSpec.describe "Level suggestion steps the card showed", type: :request do
  let(:json) { { "Content-Type" => "application/json", "Accept" => "application/json" } }
  let(:user) { create_user_with_key }

  around { |example| travel_to(Time.utc(2026, 10, 14, 15)) { example.run } }

  before { login_as(user) }

  def step(kind, from, to) = { kind: kind, from: from, to: to }

  def apply(levels, steps, version: user.reload.section_kind_preferences_version)
    patch profile_path, params: {
      user: { section_kind_levels: levels, section_kind_preferences_version: version },
      level_suggestion_steps: steps
    }.to_json, headers: json
  end

  def dismiss(kinds, steps, reason: "not_now")
    post level_suggestion_dismissal_path, params: { kinds: kinds, reason: reason, steps: steps }.to_json, headers: json
  end

  describe "Apply" do
    it "writes one target on an account without targets and leaves the skill level alone" do
      apply({ "code_review" => "mid_level" }, [ step("code_review", "junior", "mid_level") ])

      expect(response).to have_http_status(:ok)
      expect(user.reload).to have_attributes(section_kind_levels: { "code_review" => "mid_level" }, skill_level: "junior")
      expect(user.level_suggestion_events.sole).to have_attributes(
        kind: "code_review", source: "suggestion", from_level: "junior", to_level: "mid_level"
      )
    end

    it "refuses a step whose level changed since the card was shown, saving nothing" do
      patch profile_path, params: { user: { skill_level: "senior" } }.to_json, headers: json
      user.level_suggestion_events.delete_all
      cutoffs = user.reload.level_suggestion_cutoffs

      apply({ "code_review" => "mid_level" }, [ step("code_review", "junior", "mid_level") ])

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("status" => "error", "current" => include("section_kind_levels" => {}))
      expect(user.reload.section_kind_levels).to eq({})
      expect(user.level_suggestion_cutoffs).to eq(cutoffs)
      expect(user.level_suggestion_events).to be_empty
    end

    it "refuses the whole request when one of several steps is stale" do
      user.update!(section_kind_levels: { "pattern" => "mid_level" })

      apply({ "code_review" => "mid_level", "pattern" => "senior" },
            [ step("code_review", "junior", "mid_level"), step("pattern", "junior", "mid_level") ])

      expect(response).to have_http_status(:conflict)
      expect(user.reload.section_kind_levels).to eq("pattern" => "mid_level")
    end

    it "still refuses a stale preference version first" do
      apply({ "code_review" => "mid_level" }, [ step("code_review", "junior", "mid_level") ], version: 999)

      expect(response).to have_http_status(:conflict)
      expect(user.reload.section_kind_levels).to eq({})
    end

    it "refuses a step the request does not save" do
      apply({ "code_review" => "senior" }, [ step("code_review", "junior", "mid_level") ])

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.section_kind_levels).to eq({})
    end

    it "refuses steps that are not one-rung moves" do
      apply({ "code_review" => "senior" }, [ step("code_review", "junior", "senior") ])

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.section_kind_levels).to eq({})
    end

    it "labels a level change posted without a step a Setup edit, even when a proposal matches it" do
      reviewed_level_days(user, "code_review", "junior", 5, ending: Date.current - 1)

      apply({ "code_review" => "mid_level" }, nil)

      expect(response).to have_http_status(:ok)
      expect(user.level_suggestion_events.sole).to have_attributes(source: "setup_edit", to_level: "mid_level")
    end
  end

  describe "dismissal" do
    before { user.update!(section_kind_levels: ExerciseSection.keys.index_with { "junior" }) }

    it "stores the move the card showed" do
      dismiss([ "code_review" ], [ step("code_review", "junior", "mid_level") ])

      expect(response).to have_http_status(:ok)
      expect(user.level_suggestion_events.sole).to have_attributes(action: "dismissed", from_level: "junior",
                                                                    to_level: "mid_level")
    end

    it "refuses a step whose level changed since the card was shown, writing nothing" do
      user.update!(section_kind_levels: user.section_kind_levels.merge("code_review" => "mid_level"))
      user.update_column(:level_suggestion_cutoffs, {})
      user.level_suggestion_events.delete_all

      dismiss([ "code_review" ], [ step("code_review", "junior", "mid_level") ])

      expect(response).to have_http_status(:conflict)
      expect(user.reload.level_suggestion_cutoffs).to eq({})
      expect(user.level_suggestion_events).to be_empty
    end

    it "refuses steps that do not match the kinds or are malformed" do
      dismiss([ "code_review" ], [ step("pattern", "junior", "mid_level") ])
      expect(response).to have_http_status(:unprocessable_content)

      dismiss([ "code_review" ], [ step("code_review", "junior", "senior") ])
      expect(response).to have_http_status(:unprocessable_content)

      expect(user.reload.level_suggestion_cutoffs).to eq({})
      expect(user.level_suggestion_events).to be_empty
    end

    it "still accepts a dismissal with no steps from a tab opened before steps were sent" do
      post level_suggestion_dismissal_path, params: { kinds: [ "code_review" ] }.to_json, headers: json

      expect(response).to have_http_status(:ok)
    end
  end

  describe "Setup opened from the card's link" do
    before { user.update!(section_kind_levels: ExerciseSection.keys.index_with { "junior" }) }

    def mix = Nokogiri::HTML(response.body).at_css("#exercise-mix")

    it "renders each highlighted kind's step from its current level" do
      get setup_path(suggested: %w[code_review pattern], suggested_level: "mid_level")

      expect(JSON.parse(mix["data-exercise-mix-suggested-value"])).to eq(
        "code_review" => { "from" => "junior", "to" => "mid_level" },
        "pattern" => { "from" => "junior", "to" => "mid_level" }
      )
    end

    it "leaves out a kind the suggested level is not one rung from" do
      user.update!(section_kind_levels: user.section_kind_levels.merge("pattern" => "principal_engineer"))

      get setup_path(suggested: %w[code_review pattern], suggested_level: "mid_level")

      expect(JSON.parse(mix["data-exercise-mix-suggested-value"]).keys).to eq([ "code_review" ])
    end

    it "renders no steps without a suggestion" do
      get setup_path

      expect(mix["data-exercise-mix-suggested-value"]).to be_nil
    end
  end

  describe "a skill level save" do
    it "takes the row lock, so a Not now written just before it survives" do
      user.update_columns(section_kind_levels: { "pattern" => "senior" })
      concurrent = { "pattern" => { "level" => "senior", "through" => "2026-10-13" } }
      expect_any_instance_of(User).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        User.find(user.id).update_column(:level_suggestion_cutoffs, concurrent)
        original.call(*args, &block)
      end

      patch profile_path, params: { user: { skill_level: "mid_level" } }.to_json, headers: json

      expect(response).to have_http_status(:ok)
      cutoffs = user.reload.level_suggestion_cutoffs
      expect(cutoffs["code_review"]).to eq("level" => "mid_level", "through" => "2026-10-14")
      expect(cutoffs["pattern"]).to eq(concurrent["pattern"])
    end
  end
end
