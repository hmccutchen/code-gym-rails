require "rails_helper"

# DailyKinds.recorded reads a row with no pair as the default, so every writer must record one or that fallback hides it.
RSpec.describe "Every path that writes a daily exercise records its pair" do
  include ActiveSupport::Testing::TimeHelpers

  WRITE_PATHS = {
    "app/jobs/generate_daily_exercises_job.rb" => "creates the day's row from the plan's notes",
    "app/jobs/regenerate_exercise_job.rb"      => "rewrites the row's notes from the new plan",
    "app/services/preview_seed.rb"             => "seeds a preview app's past days with the user's pair"
  }.freeze

  WRITER = /(?:DailyExercise|daily_exercises)\.(?:create|new|build|insert|insert_all|upsert|upsert_all|find_or_create_by|find_or_initialize_by|create_or_find_by)\b|\bupdate(?:_columns|_column|!)?\(\s*problem_set:|\.problem_set\s*=(?!=)/

  let(:pair) { %w[architecture code_review] }
  let(:user) do
    User.create!(email: "pair-writer@example.com", name: "Pair", provider: "fake", api_keys: { "fake" => "fake-key" },
                 time_zone: "UTC", daily_section_kinds: pair)
  end

  it "knows every file under app/ and lib/ that writes a problem set, so a new writer must join this list" do
    writers = Dir[Rails.root.join("{app,lib}/**/*.{rb,rake}")].sort
      .select { |path| File.read(path, encoding: "UTF-8").match?(WRITER) }
      .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }

    expect(writers).to match_array(WRITE_PATHS.keys)
  end

  it "records the user's pair on a judged weekday set" do
    travel_to(Time.utc(2026, 10, 14, 9)) { GenerateDailyExercisesJob.perform_now(user_id: user.id) }

    expect(user.daily_exercises.sole.plan_notes["daily_kinds"]).to eq(pair)
  end

  it "records the user's pair on an unjudged weekend set" do
    travel_to(Time.utc(2026, 10, 17, 9)) { GenerateDailyExercisesJob.perform_now(user_id: user.id) }

    expect(user.daily_exercises.sole.plan_notes["daily_kinds"]).to eq(pair)
  end

  it "writes the pair onto a regenerated row that predates it" do
    legacy = DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago, language: "ruby_rails",
                                   problem_set: { "code_review" => { "question" => "old" } }, regenerating_since: Time.current)

    RegenerateExerciseJob.perform_now(user_id: user.id)

    expect(legacy.reload.plan_notes["daily_kinds"]).to eq(pair)
  end

  it "keeps a carried-forward set's own pair, since moving a held set is not a new plan" do
    held = DailyExercise.create!(user: user, date: Date.current - 1, generated_at: 1.day.ago, language: "ruby_rails",
                                 problem_set: { "code_review" => { "question" => "held" } },
                                 plan_notes: { "daily_kinds" => %w[code_review design_comparison] })
    user.update!(paused_generation_at: 2.days.ago)

    user.carry_held_set_forward!

    expect(held.reload).to have_attributes(date: Date.current, plan_notes: { "daily_kinds" => %w[code_review design_comparison] })
  end

  it "records the seeded account's own pair on every preview day" do
    ENV[PreviewEnvironment::VAR] = "1"
    ENV[PreviewSeed::EMAIL_VAR] = user.email

    expect(PreviewSeed.run!).to eq(user)
    expect(user.daily_exercises).to be_present
    expect(user.daily_exercises.map { |exercise| exercise.plan_notes["daily_kinds"] }).to all(eq(pair))
  ensure
    ENV.delete(PreviewEnvironment::VAR)
    ENV.delete(PreviewSeed::EMAIL_VAR)
  end
end
