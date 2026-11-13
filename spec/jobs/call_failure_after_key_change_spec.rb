require "rails_helper"

RSpec.describe "A failure for a call's own provider, found when its key changed" do
  include ActiveSupport::Testing::TimeHelpers
  include PracticeGenerationHelpers

  let!(:user) do
    User.create!(email: "own-failure@example.com", provider: "anthropic", time_zone: "UTC",
                 api_keys: { "anthropic" => "sk-ant-old", "openai" => "sk-proj-Ab8RN6J5yPUsY9SwLxAS2DYq" })
  end

  around { |example| travel_to(Time.utc(2026, 10, 14, 15, 0, 0)) { example.run } }

  before { allow(Rails.logger).to receive(:error) }

  def bad_key = ProviderError::AuthenticationError.new("invalid x-api-key").tap { |e| e.provider = "anthropic" }

  def replace_key = User.find(user.id).tap { |fresh| fresh.store_api_key("sk-ant-new", provider: "anthropic") }.save!

  def watch_reports
    reports = []
    allow_any_instance_of(User).to receive(:report_call_failure).and_wrap_original do |original, key_used, **options, &block|
      account = original.receiver
      reports << { key_changed: account.key_in_use != key_used,
                   own_failure: account.last_generation_failure_provider == key_used.first }
      original.call(key_used, **options, &block)
    end
    reports
  end

  def own_failures(reports) = reports.select { |report| report[:key_changed] && report[:own_failure] }

  def provider_calls(*steps)
    service = instance_double(ClaudeService)
    calls = 0
    allow(service).to receive(:generate_judged_exercise) do |*|
      calls += 1
      steps.fetch(calls - 1).call
    end
    allow(AiService).to receive(:for).with(user).and_return(service)
  end

  def failing = -> { raise bad_key }

  describe "in the daily job" do
    it "is not found when a second job tries to start during the call, since the claim stops it" do
      reports = watch_reports
      provider_calls(-> { replace_key; GenerateDailyExercisesJob.perform_now(user_id: user.id); raise bad_key }, failing)

      GenerateDailyExercisesJob.perform_now(user_id: user.id)

      expect(reports.size).to eq(1)
      expect(own_failures(reports)).to be_empty
      expect(user.reload.last_generation_error).to eq(GenerateDailyExercisesJob::SUPERSEDED_MESSAGE)
    end

    it "is not found when a job that took over a stale claim recorded one on the new key" do
      reports = watch_reports
      take_over = lambda do
        replace_key
        travel User::GENERATION_STALE_AFTER + 1.second
        GenerateDailyExercisesJob.perform_now(user_id: user.id)
        raise bad_key
      end
      provider_calls(take_over, failing)

      GenerateDailyExercisesJob.perform_now(user_id: user.id)

      expect(reports).to eq([ { key_changed: false, own_failure: false } ])
      expect(user.reload).to have_attributes(last_generation_failure: "bad_key", last_generation_failure_provider: "anthropic")
    end

    it "is not found for a failure recorded before the call, since the key change clears it" do
      user.record_generation_failure!(bad_key)
      reports = watch_reports
      provider_calls(-> { replace_key; raise bad_key })

      GenerateDailyExercisesJob.perform_now(user_id: user.id)

      expect(own_failures(reports)).to be_empty
      expect(user.reload.last_generation_error).to eq(GenerateDailyExercisesJob::SUPERSEDED_MESSAGE)
    end

    it "is not found for a legacy row, written before key changes cleared failures, which can only name another provider" do
      user.update_columns(provider: "openai", last_generation_error_date: Date.current, last_generation_failure: "bad_key",
                          last_generation_failure_provider: "anthropic", last_generation_failed_at: Time.current)
      reports = watch_reports
      switch_back = -> { User.find(user.id).tap { |fresh| fresh.use_provider("anthropic") }.save! }
      provider_calls(-> { switch_back.call; raise bad_key })

      GenerateDailyExercisesJob.perform_now(user_id: user.id)

      expect(reports).to eq([ { key_changed: true, own_failure: false } ])
      expect(user.reload).to have_attributes(last_generation_failure: "bad_key", last_generation_failure_provider: "anthropic")
    end
  end

  describe "in a regeneration" do
    let!(:exercise) do
      DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago, language: "ruby_rails",
                            problem_set: { "code_review" => { "question" => "old" } }, regenerating_since: Time.current)
    end

    it "is not found when a second run of the job fails on the new key first, since its release ends the claim" do
      reports = watch_reports
      provider_calls(-> { replace_key; RegenerateExerciseJob.perform_now(user_id: user.id); raise bad_key }, failing)

      RegenerateExerciseJob.perform_now(user_id: user.id)

      expect(reports).to eq([ { key_changed: false, own_failure: false } ])
      expect(user.reload).to have_attributes(last_generation_failure: "bad_key", last_generation_failure_provider: "anthropic")
    end

    it "is not found when the daily job runs during the call, since today's set stops it" do
      reports = watch_reports
      provider_calls(-> { replace_key; GenerateDailyExercisesJob.perform_now(user_id: user.id); raise bad_key })

      RegenerateExerciseJob.perform_now(user_id: user.id)

      expect(reports).to eq([ { key_changed: true, own_failure: false } ])
      expect(user.reload.generation_failed_today?).to be(false)
    end
  end
end
