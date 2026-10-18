require "rails_helper"

RSpec.describe DailyKindSwap::Picker do
  include AuthHelpers

  let(:user) { create_fake_provider_user }

  def exercise(problem_set: { "code_review" => { "q" => 1 }, "design_comparison" => { "q" => 1 }, "pattern" => { "q" => 1 } },
               daily: %w[code_review design_comparison], size: 3)
    @exercise ||= DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
                                        problem_set: problem_set, plan_notes: { "daily_kinds" => daily, "size" => size })
  end

  def pickers(response: nil) = described_class.for_day(user.reload, exercise: @exercise || exercise, response: response)

  def option(picker, key) = picker.options.find { |option| option.kind.key == key }

  describe ".for_day" do
    it "gives each delivered daily card its place's picker, keyed by the card's kind" do
      result = pickers

      expect(result.keys).to eq(%w[code_review design_comparison])
      expect(result.transform_values(&:place)).to eq("code_review" => 0, "design_comparison" => 1)
    end

    it "gives a judge-dropped daily section no control, and never moves one onto another card" do
      exercise(problem_set: { "code_review" => { "q" => 1 }, "pattern" => { "q" => 1 } })

      expect(pickers.keys).to eq(%w[code_review])
    end

    it "matches cards to the row's recorded pair, and reads the place's kind from the user's pair" do
      user.update!(daily_section_kinds: %w[code_review architecture])
      exercise

      expect(pickers["design_comparison"].current).to eq(ExerciseSection::Architecture)
    end

    it "gives no pickers without a set" do
      expect(described_class.for_day(user, exercise: nil, response: nil)).to eq({})
    end
  end

  describe "the first-time hint" do
    it "shows on the first daily card only, for an account with no swaps and few submitted days" do
      expect(pickers.transform_values(&:hint?)).to eq("code_review" => true, "design_comparison" => false)
    end

    it "is gone once the account has swapped, or on a submitted set" do
      user.daily_kind_swap_events.create!(place: 0, from_kind: "code_review", to_kind: "pattern", today_section: "no_set")
      expect(pickers.values.map(&:hint?)).to all(be(false))

      user.daily_kind_swap_events.delete_all
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current)
      expect(pickers(response: response).values.map(&:hint?)).to all(be(false))
    end

    it "is gone after enough submitted days" do
      described_class::HINT_UNTIL_SUBMITTED_DAYS.times do |n|
        day = DailyExercise.create!(user: user, date: Date.current - (n + 1), language: "ruby_rails", generated_at: Time.current,
                                    problem_set: { "code_review" => { "q" => 1 } })
        DailyResponse.create!(user: user, daily_exercise: day, date: day.date, submitted_at: Time.current)
      end

      expect(pickers.values.map(&:hint?)).to all(be(false))
    end
  end

  describe "options" do
    it "marks the current kind, disables the other daily kind and offers the rest" do
      picker = pickers["code_review"]

      expect(option(picker, "code_review")).to have_attributes(state: :now, consequences: nil)
      expect(option(picker, "design_comparison")).to have_attributes(state: :disabled, note: "Already a daily section")
      expect(option(picker, "challenge").state).to eq(:available)
      expect(option(picker, "challenge").consequences).to be_a(DailyKindSwap::Consequences::Result)
      expect(picker.options.map { |option| option.kind.key }).to eq(ExerciseSection.keys)
    end

    it "disables the other fourths while a fourth is the other daily kind, naming all three" do
      user.update!(daily_section_kinds: %w[code_review plan_review])
      picker = pickers["code_review"]

      expect(option(picker, "ambiguity_hunt")).to have_attributes(
        state: :disabled, note: "Only one of Plan Review, Ambiguity Hunt and Pseudocode to Code can be a daily section."
      )
    end

    it "disables a kind whose swap would leave a group with nothing to rotate, saying which kinds are off" do
      user.update!(excluded_section_kinds: %w[security_review challenge parsons_problem])
      picker = pickers["code_review"]

      expect(option(picker, "architecture").state).to eq(:disabled)
      expect(option(picker, "architecture").note).to include("Coding Challenge").and include("Security Review")
    end

    it "reads today's planned size for the outgoing warning" do
      exercise(size: 2)

      expect(option(pickers["code_review"], "challenge").consequences.warning.first).to include("about once every")
    end
  end

  it "adds the paused sentence to the next-set line while generation is paused" do
    expect(pickers["code_review"].next_set_line).to eq(I18n.t("daily_kinds.picker.next_set"))

    user.update!(paused_generation_at: Time.current)
    expect(pickers["code_review"].next_set_line).to eq(I18n.t("daily_kinds.picker.next_set_paused"))
  end
end
