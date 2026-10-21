require "rails_helper"

RSpec.describe ProfileUpdate, type: :model do
  let(:user) { create_user_with_key }

  def save(account = user, **params)
    described_class.new(account, ActionController::Parameters.new(params)).save
  end

  def refused(user_params)
    outcome = save(user.reload, user: user_params)
    expect(outcome.status).to eq(:invalid), "#{user_params.inspect} was accepted"
    outcome.error
  end

  it "saves the posted fields and reports it" do
    expect(save(user: { name: " Renamed ", time_zone: " UTC " }).status).to eq(:saved)

    expect(user.reload).to have_attributes(name: "Renamed", time_zone: "UTC")
  end

  describe "the posted shape" do
    it "refuses a value strong params would drop or Active Record would misread, and saves nothing else" do
      original = user.reload.attributes

      [ { section_kind_weights: [] }, { excluded_section_kinds: [ { "a" => 1 } ] }, { section_kind_levels: nil },
        { locked_section_kinds: nil }, { display_preferences: "light" },
        { skill_level: [ "senior" ] }, { level_suggestions: "yes" }, { name: [ "x" ] }, { time_zone: {} },
        { daily_section_count: "2.5" }, { daily_section_count: "" }, { daily_section_count: nil }, { daily_section_count: 2.0 } ]
        .each { |payload| refused({ name: "Not saved" }.merge(payload)) }

      expect(user.reload.attributes).to eq(original)
    end

    it "accepts a whole number or the word for the daily section count and leaves the range to the user" do
      expect(save(user: { daily_section_count: "3" }).status).to eq(:saved)
      expect(save(user: { daily_section_count: User::AUTOMATIC_SECTION_COUNT }).status).to eq(:saved)
      expect(user.reload.daily_section_count).to be_nil

      expect(refused(daily_section_count: 9)).to eq(
        "Daily sections must be #{User::AUTOMATIC_SECTION_COUNT} or one of #{User::DAILY_SECTION_COUNTS.to_a.join(', ')}"
      )
    end

    it "leaves which values a field allows to the user's own validators" do
      expect(refused(section_kind_weights: { "challenge" => 3 })).to include("unsupported weight for challenge")
      expect(refused(section_kind_levels: { "challenge" => "strong" })).to include(KindDifficulty::LEVELS.join(", "))
      expect(refused(skill_level: "expert")).to eq("Skill level must be one of #{User::SKILL_LEVELS.join(', ')}")
      expect(refused(display_preferences: { "theme" => "neon" })).to include("unsupported theme")
      expect(refused(locked_section_kinds: [ "challenge" ])).to include("without a difficulty target")
      expect(refused(display_preferences: { "contrast" => nil })).to include("unknown setting: contrast")
    end

    it "refuses an unknown time zone posted with a target change instead of reading it for the cutoff" do
      expect(refused(time_zone: "Mars/Phobos", section_kind_levels: { "pattern" => "senior" })).to include("valid time zone")

      expect(user.reload).to have_attributes(section_kind_levels: {}, level_suggestion_cutoffs: {})
    end

    it "refuses a page from before tracks per level" do
      expect(refused(learning_track: "junior")).to eq(I18n.t("tracks.stale_page"))
    end

    it "refuses a track change posted with an Exercise mix field" do
      expect(refused(skill_level: "senior", section_kind_levels: {})).to eq("Change the track and the exercise mix in separate saves.")
    end

    it "refuses steps it cannot parse" do
      outcome = save(user: { section_kind_levels: {} }, level_suggestion_steps: [ { "kind" => "pattern" } ])

      expect(outcome).to have_attributes(status: :invalid, error: I18n.t("level_suggestion.card.invalid_steps"))
    end
  end

  describe "under the user-row lock" do
    it "reports a stale version without saving" do
      outcome = save(user: { section_kind_levels: { "pattern" => "senior" }, section_kind_preferences_version: 99 })

      expect(outcome).to have_attributes(status: :stale, layout_changed: false)
      expect(user.reload.section_kind_levels).to eq({})
    end

    it "reports a page rendered for another daily pair as a layout change" do
      outcome = save(user: { section_kind_levels: {} }, layout: [ "pattern", "code_review" ])

      expect(outcome).to have_attributes(status: :stale, layout_changed: true)
    end

    it "reports a shown step whose rung has moved since the card rendered" do
      steps = [ { "kind" => "pattern", "from" => "mid_level", "to" => "senior" } ]

      expect(save(user: { section_kind_levels: { "pattern" => "senior" } }, level_suggestion_steps: steps).status).to eq(:stale)
    end

    it "refuses a shown step the request does not save" do
      steps = [ { "kind" => "pattern", "from" => "junior", "to" => "mid_level" } ]

      outcome = save(user: { section_kind_levels: {} }, level_suggestion_steps: steps)

      expect(outcome).to have_attributes(status: :invalid, error: I18n.t("level_suggestion.card.invalid_steps"))
    end

    it "records the first-run track choice once" do
      account = create_user_with_key(email: "first@example.com", track_chosen: false)

      expect(save(account, user: { choose_track: true, skill_level: "senior" }).status).to eq(:saved)
      expect(save(account, user: { choose_track: true, skill_level: "junior" }))
        .to have_attributes(status: :invalid, error: "That track choice isn't available.")
      expect(account.reload.skill_level).to eq("senior")
    end
  end
end
