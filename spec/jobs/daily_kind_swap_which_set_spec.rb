require "rails_helper"

RSpec.describe "Which set a daily kind swap first applies to" do
  include ActiveSupport::Testing::TimeHelpers
  include AuthHelpers

  let!(:user) { create_fake_provider_user }
  let(:default_pair) { DailyKinds::DEFAULT.map(&:key) }
  let(:new_pair) { [ default_pair.first, "architecture" ] }
  let(:wednesday) { Time.utc(2026, 10, 14, 9) }

  def swap!
    outcome = DailyKindSwap.call(user.reload, place: 1, kind: "architecture", version: user.section_kind_preferences_version)
    expect(outcome.status).to eq(:saved)
  end

  def pair_of(exercise) = exercise.reload.plan_notes["daily_kinds"]

  it "leaves today's set untouched and plans the next weekday's set from the new pair" do
    travel_to(wednesday) { GenerateDailyExercisesJob.perform_now }
    today = user.daily_exercises.sole
    before = today.attributes.slice("problem_set", "plan_notes")

    travel_to(wednesday + 1.hour) { swap! }

    expect(today.reload.attributes.slice("problem_set", "plan_notes")).to eq(before)
    expect(pair_of(today)).to eq(default_pair)
    travel_to(wednesday + 1.day) { GenerateDailyExercisesJob.perform_now }
    expect(pair_of(user.daily_exercises.find_by!(date: Date.new(2026, 10, 15)))).to eq(new_pair)
  end

  it "keeps a carried-forward held set's pair and uses the new one for the set after it is submitted" do
    travel_to(wednesday) { GenerateDailyExercisesJob.perform_now(user_id: user.id) }
    held = user.daily_exercises.sole
    user.update!(paused_generation_at: wednesday)

    travel_to(wednesday + 1.day) do
      swap!
      expect(user.carry_held_set_forward!).to eq(held)
      expect(held.reload).to have_attributes(date: Date.current)
      expect(pair_of(held)).to eq(default_pair)
      held.create_daily_response!(user: user, date: Date.current, submitted_at: Time.current)
    end

    travel_to(wednesday + 2.days) { GenerateDailyExercisesJob.perform_now(user_id: user.id) }
    expect(pair_of(user.daily_exercises.find_by!(date: Date.new(2026, 10, 16)))).to eq(new_pair)
  end

  it "generates nothing for a paused account until it asks, and that set uses the new pair" do
    user.update!(paused_generation_at: wednesday - 1.day)

    travel_to(wednesday) do
      swap!
      GenerateDailyExercisesJob.perform_now
      expect(user.daily_exercises).to be_empty

      GenerateDailyExercisesJob.perform_now(user_id: user.id)
    end

    expect(pair_of(user.daily_exercises.sole)).to eq(new_pair)
  end

  it "plans a regeneration after a swap from the new pair" do
    travel_to(wednesday) do
      GenerateDailyExercisesJob.perform_now(user_id: user.id)
      today = user.daily_exercises.sole
      swap!
      today.update!(regenerating_since: Time.current)

      RegenerateExerciseJob.perform_now(user_id: user.id)

      expect(pair_of(today)).to eq(new_pair)
    end
  end
end
