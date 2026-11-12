require "rails_helper"

RSpec.describe "Holding scheduled generation for an account whose key keeps failing" do
  include ActiveJob::TestHelper
  include PracticeGenerationHelpers

  let(:monday_morning) { Time.utc(2026, 7, 13, 13, 0) }
  let!(:user) do
    User.create!(email: "dead-key@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "UTC")
  end

  around { |example| travel_to(monday_morning) { example.run } }

  def bad_key = ProviderError::AuthenticationError.new("invalid x-api-key")

  def out_of_credit = ProviderError::BillingError.new("credit balance is too low")

  def failures = user.reload.generation_account_failures

  def provider_raising(*errors)
    calls = []
    service = instance_double(ClaudeService)
    allow(service).to receive(:generate_judged_exercise) do |*|
      calls << :call
      raise errors[calls.size - 1] || errors.last
    end
    allow(AiService).to receive(:for).with(user).and_return(service)
    allow(Rails.logger).to receive(:error)
    calls
  end

  def provider_succeeding
    calls = []
    judged = AiService::JudgedSet.new(problem_set: { "code_review" => {} }, dropped_sections: [], outcomes: {}, plan_notes: {})
    service = instance_double(ClaudeService)
    allow(service).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:|
      calls << :call
      with_practice_context(judged, user: caller, language: language, schedule_context: schedule_context)
    end
    allow(AiService).to receive(:for).with(user).and_return(service)
    calls
  end

  def run_hand_out_and_its_jobs
    EnqueueDueGenerationsJob.new.perform
    perform_enqueued_jobs(only: GenerateDailyExercisesJob)
  end

  def scheduled_job = have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id, scheduled: true)

  describe "the hourly hand-out" do
    it "keeps enqueueing after one bad-key failure, and stops after the second" do
      calls = provider_raising(bad_key)

      run_hand_out_and_its_jobs
      travel 1.hour
      run_hand_out_and_its_jobs
      expect(calls.size).to eq(2)

      travel 1.hour
      expect { EnqueueDueGenerationsJob.new.perform }.not_to have_enqueued_job(GenerateDailyExercisesJob)
      travel 1.day
      expect { EnqueueDueGenerationsJob.new.perform }.not_to have_enqueued_job(GenerateDailyExercisesJob)
      expect(calls.size).to eq(2)
    end

    it "stops after two out-of-credit failures" do
      calls = provider_raising(out_of_credit)

      3.times do
        run_hand_out_and_its_jobs
        travel 1.hour
      end

      expect(calls.size).to eq(2)
      expect(user.reload.last_generation_failure).to eq("out_of_credit")
    end

    it "stops after one of each" do
      calls = provider_raising(bad_key, out_of_credit)

      3.times do
        run_hand_out_and_its_jobs
        travel 1.hour
      end

      expect(calls.size).to eq(2)
    end

    it "never stops for rate limits or outages, however many there are" do
      calls = provider_raising(ProviderError::RateLimitError.new("slow down", http_status: 429),
                               ProviderError.new("bad gateway", http_status: 502),
                               ProviderError::NetworkError.new("connection reset"))

      4.times do
        run_hand_out_and_its_jobs
        travel 1.hour
      end

      expect(calls.size).to eq(4)
      expect(failures).to eq(0)
    end

    it "does not pause the held account" do
      provider_raising(bad_key)

      2.times do
        run_hand_out_and_its_jobs
        travel 1.hour
      end

      expect(user.reload).to have_attributes(generation_account_failures: 2, paused_generation_at: nil, generation_pause_source: nil)
    end
  end

  describe "a scheduled job already queued when the hold begins" do
    it "re-checks and calls no provider" do
      calls = provider_raising(bad_key)
      user.update_columns(generation_account_failures: ScheduledGeneration::KEY_HOLD_AFTER)

      GenerateDailyExercisesJob.perform_now(user_id: user.id, scheduled: true)

      expect(calls).to be_empty
      expect(failures).to eq(ScheduledGeneration::KEY_HOLD_AFTER)
    end
  end

  describe "a generation the user starts while held" do
    before { user.update_columns(generation_account_failures: ScheduledGeneration::KEY_HOLD_AFTER) }

    it "still runs, and lifts the hold when it succeeds" do
      calls = provider_succeeding

      GenerateDailyExercisesJob.perform_now(user_id: user.id)

      expect(calls.size).to eq(1)
      expect(user.daily_exercises.for_date(Date.current).count).to eq(1)
      expect(failures).to eq(0)
    end

    it "lets the hand-out enqueue again the next morning after that success" do
      provider_succeeding
      GenerateDailyExercisesJob.perform_now(user_id: user.id)

      travel 1.day
      expect { EnqueueDueGenerationsJob.new.perform }.to scheduled_job.once
    end

    it "still runs and keeps the hold when the key fails again, leaving the existing failure message" do
      calls = provider_raising(bad_key)

      GenerateDailyExercisesJob.perform_now(user_id: user.id)

      expect(calls.size).to eq(1)
      expect(failures).to be >= ScheduledGeneration::KEY_HOLD_AFTER
      expect(user.reload.generation_failure_message(surface: :generation))
        .to eq("Claude didn't accept your API key, so nothing was generated. Check the key in Setup.")
    end
  end

  describe "a success with one failure on the count" do
    it "sets the count back to zero, so two failures must come in a row" do
      user.update_columns(generation_account_failures: 1)
      provider_succeeding

      GenerateDailyExercisesJob.perform_now(user_id: user.id, scheduled: true)

      expect(failures).to eq(0)
    end
  end

  describe "a job whose claim was taken over during the call" do
    it "does not count its failure, which the job that took the claim will report" do
      service = instance_double(ClaudeService)
      allow(service).to receive(:generate_judged_exercise) do |caller, **|
        travel User::GENERATION_STALE_AFTER + 1.second
        User.find(caller.id).claim_generating!
        raise bad_key
      end
      allow(AiService).to receive(:for).with(user).and_return(service)
      allow(Rails.logger).to receive(:error)

      GenerateDailyExercisesJob.perform_now(user_id: user.id)

      expect(user.reload).to have_attributes(generation_account_failures: 0, last_generation_failure: nil)
    end

    it "counts the failure of a job that still holds its claim" do
      provider_raising(bad_key)

      GenerateDailyExercisesJob.perform_now(user_id: user.id)

      expect(failures).to eq(1)
    end

    it "does not count a failure when another job wrote today's set during the call" do
      service = instance_double(ClaudeService)
      allow(service).to receive(:generate_judged_exercise) do |caller, **|
        DailyExercise.create!(user: caller, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                              problem_set: { "code_review" => {} })
        raise bad_key
      end
      allow(AiService).to receive(:for).with(user).and_return(service)
      allow(Rails.logger).to receive(:error)

      GenerateDailyExercisesJob.perform_now(user_id: user.id)

      expect(failures).to eq(0)
    end
  end
end
