require "rails_helper"

RSpec.describe DailyKindSwap do
  include AuthHelpers

  let(:user) { create_fake_provider_user }

  def swap(place: 0, kind: "pattern", version: user.reload.section_kind_preferences_version)
    described_class.call(user, place: place, kind: kind, version: version)
  end

  def todays_set(sections: %w[code_review design_comparison], plan_notes: { "daily_kinds" => %w[code_review design_comparison], "size" => 2 })
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: sections.index_with { |key| { "concept" => "n_plus_one", "kind" => key } },
                          plan_notes: plan_notes)
  end

  def response_for(exercise, **attrs)
    DailyResponse.create!(user: user, daily_exercise: exercise, date: exercise.date, **attrs)
  end

  describe "a saved swap" do
    it "stores the pair in place order, bumps the preferences version and says it starts with the next set" do
      version = user.section_kind_preferences_version

      outcome = swap(place: 1, kind: "architecture")

      expect(outcome).to be_saved
      expect(user.reload.daily_section_kinds).to eq(%w[code_review architecture])
      expect(user.section_kind_preferences_version).to eq(version + 1)
      expect(outcome).to have_attributes(message: "Saved. This starts with your next set.",
                                         daily_kinds: %w[code_review architecture], version: version + 1)
    end

    it "stores nothing when the pair returns to the default, so the account reads as untouched" do
      swap(place: 1, kind: "architecture")
      swap(place: 1, kind: "design_comparison")

      expect(user.reload.daily_section_kinds).to eq([])
    end

    it "never changes today's set or its response" do
      exercise = todays_set
      response = response_for(exercise, answers: { "code_review" => "x" * 20 })

      expect { swap }.not_to(change { [ exercise.reload.attributes, response.reload.attributes ] })
    end

    it "names the pause in its reply while generation is paused" do
      user.update!(paused_generation_at: Time.current)

      expect(swap.message).to eq("Saved. This starts with your next set. Generation is paused, so that's the next set " \
                                 "you generate or the first one after you resume.")
    end
  end

  describe "the want-it-today line" do
    let(:line) { "Want it in today's set? Generate a new set. This replaces every answer you've typed so far." }

    it "shows while today's set can be regenerated and nothing is submitted" do
      response_for(todays_set, answers: { "code_review" => "x" * 20 })

      expect(swap.want_it_today).to eq(line)
    end

    it "stays hidden once today's set is submitted, regenerated, or missing" do
      expect(swap(kind: "pattern").want_it_today).to be_nil

      exercise = todays_set
      response = response_for(exercise, submitted_at: Time.current)
      expect(swap(kind: "architecture").want_it_today).to be_nil

      response.destroy!
      exercise.update!(regenerated_at: Time.current)
      expect(swap(kind: "challenge").want_it_today).to be_nil
    end
  end

  describe "the event row" do
    def recorded(**args)
      swap(**args)
      user.daily_kind_swap_events.order(:id).last
    end

    it "records the place, both kinds, the setting and no set on a day without one" do
      user.update!(daily_section_count: 3)

      expect(recorded(place: 1, kind: "challenge")).to have_attributes(
        place: 1, from_kind: "design_comparison", to_kind: "challenge", today_section: "no_set",
        planned_size: nil, size_setting: 3
      )
    end

    it "reads the outgoing section's state in today's set, checking that the set holds it first" do
      exercise = todays_set(sections: %w[code_review pattern], plan_notes: { "size" => 2 })
      expect(recorded(place: 1, kind: "challenge")).to have_attributes(today_section: "not_in_set", planned_size: 2)

      response = response_for(exercise)
      expect(recorded(place: 0, kind: "architecture")).to have_attributes(today_section: "unanswered")

      user.update!(daily_section_kinds: [])
      response.update!(answers: { "code_review" => "x" * 20 })
      expect(recorded(place: 0, kind: "architecture")).to have_attributes(today_section: "answered")

      user.update!(daily_section_kinds: [])
      response.update!(submitted_at: Time.current)
      expect(recorded(place: 0, kind: "architecture")).to have_attributes(today_section: "submitted")
    end

    it "keeps an unknown size for a set planned before plan_notes recorded one" do
      todays_set(plan_notes: {})

      expect(recorded).to have_attributes(today_section: "unanswered", planned_size: nil)
    end
  end

  describe "a refused swap" do
    def expect_refused(reason, **args)
      before = [ user.reload.daily_section_kinds, user.section_kind_preferences_version ]

      outcome = swap(**args)

      expect(outcome).to have_attributes(status: :refused, reason: reason)
      expect([ user.reload.daily_section_kinds, user.section_kind_preferences_version ]).to eq(before)
      expect(user.daily_kind_swap_events).to be_empty
      outcome
    end

    it "refuses a place or kind that does not exist" do
      expect_refused(:invalid_place, place: 2)
      expect_refused(:invalid_place, place: "first")
      expect_refused(:unknown_kind, kind: "retired_kind")
    end

    it "refuses a page whose preferences version is behind or missing" do
      expect(expect_refused(:stale, version: user.section_kind_preferences_version - 1).message)
        .to eq("Your daily sections changed in another tab. Reload the page to see them.")
      expect_refused(:stale, version: nil)
    end

    it "refuses the kind already in the place, and the other daily kind" do
      expect_refused(:unchanged, place: 0, kind: "code_review")
      expect_refused(:already_daily, place: 0, kind: "design_comparison")
    end

    it "refuses a second fourth kind, naming the three" do
      user.update!(daily_section_kinds: %w[code_review plan_review])

      expect(expect_refused(:second_fourth, place: 0, kind: "ambiguity_hunt").message)
        .to eq("Only one of Plan Review, Ambiguity Hunt and Pseudocode to Code can be a daily section.")
    end

    it "refuses a swap that would leave every remaining kind in a group turned off" do
      user.update!(excluded_section_kinds: %w[challenge security_review parsons_problem])

      outcome = expect_refused(:empties_a_slot, place: 1, kind: "architecture")

      expect(outcome.message).to include("Coding Challenge", "Security Review", "Parsons Problem", "nothing to rotate")
    end
  end

  describe ".refusal" do
    it "answers the same pair rules without a version, for marking options the picker can't offer" do
      user.update!(daily_section_kinds: %w[code_review plan_review])

      expect(described_class.refusal(user, place: 0, kind: "pseudocode_to_code")).to eq(:second_fourth)
      expect(described_class.refusal(user, place: 1, kind: "pseudocode_to_code")).to be_nil
      expect(described_class.refusal(user, place: 0, kind: "plan_review")).to eq(:already_daily)
    end
  end
end
