require "rails_helper"

RSpec.describe GenerateDailyExercisesJob do
  include ActiveSupport::Testing::TimeHelpers
  include ActiveJob::TestHelper
  include PracticeGenerationHelpers

  let(:user) { User.create!(email: "cronuser@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "UTC") }

  def stub_provider(u = user, problem_set: { "code_review" => {} }, dropped: [], notes: {}, solves: [])
    judged = AiService::JudgedSet.new(problem_set: problem_set, dropped_sections: dropped, outcomes: {}, plan_notes: notes, solves: solves)
    svc = instance_double(ClaudeService)
    allow(svc).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:|
      with_practice_context(judged, user: caller, language: language, schedule_context: schedule_context)
    end
    allow(AiService).to receive(:for).with(u).and_return(svc)
    svc
  end

  def stub_provider_failure(error, message, u = user)
    svc = instance_double(ClaudeService)
    allow(svc).to receive(:generate_judged_exercise).and_raise(*[ error, message ].compact)
    allow(AiService).to receive(:for).with(u).and_return(svc)
  end

  def run_batch_and_its_jobs
    described_class.new.perform
    perform_enqueued_jobs(only: described_class)
  end

  it "discards one already-billed inactive draft after an explicit settings edit, without retrying" do
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", false)
    service = stub_provider
    expect(service).to receive(:generate_judged_exercise).once do |_caller, language:, schedule_context:|
      expect(schedule_context[:active]).to be(false)
      expect(language).to eq("ruby_rails")
      User.find(user.id).update!(daily_section_count: 2)
      AiService::JudgedSet.new(problem_set: { "code_review" => { "question" => "paid draft" } },
        dropped_sections: [], outcomes: {}, plan_notes: {}, schedule_context: schedule_context)
    end
    expect { described_class.new.perform(user_id: user.id) }.not_to change { user.daily_exercises.count }
    expect(user.reload).to have_attributes(daily_section_count: 2, last_generation_error_date: Date.current,
      last_generation_error: "Settings or another set changed while this set was being prepared. Generate again when ready.")
  end

  describe "the user named in log lines" do
    let(:logged) { StringIO.new }

    before { allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(logged)) }

    def expect_logged_by_id
      expect(logged.string).to include("user #{user.id}")
      expect(logged.string).not_to include(user.email)
    end

    it "names the user by id on success" do
      stub_provider
      described_class.new.perform(user_id: user.id)
      expect_logged_by_id
    end

    [ ProviderError, ProviderError::AuthenticationError, ProviderError::RateLimitError, ProviderError::TimeoutError ].each do |error|
      it "names the user by id on #{error.name.demodulize}" do
        stub_provider_failure(error, "boom")
        described_class.new.perform(user_id: user.id)
        expect_logged_by_id
      end
    end

    it "names the user by id when a concurrent job already generated the day" do
      stub_provider
      expect_any_instance_of(DailyExercise).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique.new("duplicate key"))
      described_class.new.perform(user_id: user.id)
      expect_logged_by_id
    end
  end

  it "creates a DailyExercise from the provider's generated problem set" do
    stub_provider

    described_class.new.perform(user_id: user.id)

    exercise = DailyExercise.find_by(user: user, date: Date.current)
    expect(exercise.problem_set).to eq("code_review" => {})
  end

  it "does not touch last_generation_error fields on success" do
    stub_provider

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error_date).to be_nil
    expect(user.last_generation_error).to be_nil
  end

  it "clears a prior failure once generation succeeds" do
    user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
    stub_provider

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error_date).to be_nil
    expect(user.last_generation_error).to be_nil
  end

  it "logs and continues when ProviderError is raised" do
    stub_provider_failure(ProviderError, "boom")

    expect(Rails.logger).to receive(:error).with(/Failed to generate exercise.*boom/)
    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
    expect(DailyExercise.exists?(user: user, date: Date.current)).to be false
  end

  it "records a setup error as a setup failure, so the dashboard stops waiting and words it as setup" do
    allow(AiService).to receive(:for).with(user).and_raise(SetupError, "User #{user.id} has no recognized AI provider configured")
    allow(Rails.logger).to receive(:error)

    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
    expect(user.reload).to have_attributes(last_generation_failure: "setup", last_generation_error_date: Date.current)
    expect(user.generation_failure_message(surface: :generation)).to include("setup has a problem").and include("Check your provider")
    expect(Rails.logger).to have_received(:error).with(/user #{user.id}.*no recognized AI provider/)
  end

  it "records a setup failure for a user whose stored language is invalid, with no stubbed provider" do
    user.update_columns(language: "cobol")
    allow(Rails.logger).to receive(:error)

    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
    expect(user.reload).to have_attributes(last_generation_failure: "setup", last_generation_error_date: Date.current)
    expect(DailyExercise.exists?(user: user, date: Date.current)).to be false
  end

  it "records a rejected key as bad_key and renders a Setup-pointing sentence" do
    stub_provider_failure(ProviderError::AuthenticationError, "invalid x-api-key")

    expect(Rails.logger).to receive(:error).with(/Failed to generate exercise.*\(bad_key\).*invalid x-api-key/)
    described_class.new.perform(user_id: user.id)

    user.reload
    expect(user.last_generation_error_date).to eq(Date.current)
    expect(user.last_generation_failure).to eq("bad_key")
    expect(user.last_generation_failed_at).to be_within(1.minute).of(Time.current)
    expect(user.last_generation_error).to be_nil
    expect(user.generation_failure_message(surface: :generation))
      .to eq("Claude didn't accept your API key, so nothing was generated. Check the key in Setup.")
  end

  it "records a 429 as a short rate limit" do
    stub_provider_failure(ProviderError::RateLimitError, "rate limited")
    allow(Rails.logger).to receive(:error)

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_failure).to eq("short_rate_limit")
    expect(user.generation_failure_message(surface: :generation)).to start_with("Claude is limiting requests right now, so nothing was generated.")
  end

  # A key switch before the dashboard reads the failure must not relabel it.
  it "stores the provider tried and its wait, and keeps naming that provider after a switch" do
    error = ProviderError::RateLimitError.new("rate limited", retry_after: 300).tap { |e| e.provider = "anthropic" }
    stub_provider_failure(error, nil)
    allow(Rails.logger).to receive(:error)

    described_class.new.perform(user_id: user.id)

    user.reload
    expect(user.last_generation_failure_provider).to eq("anthropic")
    expect(user.last_generation_retry_after).to eq(300)
    user.update!(provider: "gemini", api_keys: { "gemini" => "AIzaTestKey" })
    expect(user.generation_failure_message(surface: :generation))
      .to eq("Claude is limiting requests right now, so nothing was generated. Try again in about 5 minutes.")
  end

  it "records a generic ProviderError as other and never stores its message" do
    stub_provider_failure(ProviderError, "boom")
    allow(Rails.logger).to receive(:error)

    described_class.new.perform(user_id: user.id)

    user.reload
    expect(user.last_generation_error_date).to eq(Date.current)
    expect(user.last_generation_failure).to eq("other")
    expect(user.last_generation_error).to be_nil
    expect(user.generation_failure_message(surface: :generation)).not_to include("boom")
  end

  it "persists a failure and writes no day when the judge rejects every section" do
    allow_any_instance_of(ClaudeService).to receive(:generate_judged_exercise).and_raise(ProviderError::AllSectionsRejectedError)
    allow(Rails.logger).to receive(:error)

    described_class.new.perform(user_id: user.id)

    user.reload
    expect(DailyExercise.exists?(user: user, date: Date.current)).to be false
    expect(user.last_generation_error).to eq(ProviderError::AllSectionsRejectedError.new.message)
  end

  it "persists the failure date in the user's own time zone" do
    pac = User.create!(email: "pac2@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles")
    stub_provider_failure(ProviderError, "boom", pac)
    allow(Rails.logger).to receive(:error)

    # 2026-07-13 06:00 UTC == 2026-07-12 23:00 PDT — still July 12th in LA.
    travel_to(Time.utc(2026, 7, 13, 6, 0)) do
      described_class.new.perform(user_id: pac.id)
    end

    expect(pac.reload.last_generation_error_date).to eq(Date.new(2026, 7, 12))
  end

  it "persists the resolved language on the created DailyExercise" do
    user.update!(language: "javascript")
    stub_provider

    described_class.new.perform(user_id: user.id)

    exercise = DailyExercise.find_by(user: user, date: Date.current)
    expect(exercise.language).to eq("javascript")
  end

  it "logs and continues when a concurrent job already created today's exercise (unique index race)" do
    stub_provider
    expect_any_instance_of(DailyExercise).to receive(:save!).and_raise(
      ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint")
    )

    expect(Rails.logger).to receive(:info).with(/Skipped duplicate generation/)
    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
    expect(user.reload.last_generation_error_date).to be_nil
  end

  it "records a timeout without the socket internals it came from" do
    stub_provider_failure(ProviderError::TimeoutError, "Network error calling Claude: Net::ReadTimeout with #<TCPSocket:(closed)>")
    allow(Rails.logger).to receive(:error)

    described_class.new.perform(user_id: user.id)

    user.reload
    expect(user.last_generation_error_date).to eq(Date.current)
    expect(user.last_generation_failure).to eq("timeout")
    expect(user.generation_failure_message(surface: :generation))
      .to eq("Claude took too long to answer, so nothing was generated. Try again.")
  end

  # A failure banner above a set a concurrent generation already created would stay all day.
  it "does not persist a failure when today's exercise already exists" do
    DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} },
                          generated_at: Time.current, language: "ruby_rails")
    stub_provider_failure(ProviderError, "boom")
    allow(Rails.logger).to receive(:error)

    described_class.new.send(:generate_for, user)

    expect(user.reload.last_generation_error_date).to be_nil
    expect(user.last_generation_error).to be_nil
  end

  it "clears a stale failure flag when today's exercise already exists" do
    user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
    DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} },
                          generated_at: Time.current, language: "ruby_rails")
    stub_provider_failure(ProviderError, "boom")
    allow(Rails.logger).to receive(:error)

    described_class.new.send(:generate_for, user)

    expect(user.reload.last_generation_error_date).to be_nil
    expect(user.last_generation_error).to be_nil
  end

  it "writes the plan notes with the row on both paths" do
    notes = { "shared_concept" => "feature_envy" }
    svc = stub_provider(notes: notes)
    returned = nil
    allow(svc).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:|
      result = AiService::JudgedSet.new(problem_set: { "code_review" => {} }, dropped_sections: [], outcomes: {}, plan_notes: notes)
      returned = with_practice_context(result, user: caller, language: language, schedule_context: schedule_context)
    end

    travel_to(Time.utc(2026, 7, 13, 15, 0)) do
      described_class.new.perform(user_id: user.id)
      expect(DailyExercise.find_by(user: user, date: Date.current).plan_notes).to eq(returned.plan_notes)
      expect(returned.plan_notes).to include(notes).and have_key("practice_schedule")
    end
    travel_to(Time.utc(2026, 7, 18, 15, 0)) do
      described_class.new.perform(user_id: user.id)
      expect(DailyExercise.find_by(user: user, date: Date.current).plan_notes).to eq(returned.plan_notes)
      expect(returned.plan_notes).to include(notes).and have_key("practice_schedule")
    end
  end

  it "judges on the cron path and records dropped sections" do
    stub_provider(problem_set: { "code_review" => { "question" => "q", "concept" => "n_plus_one" } }, dropped: [ "pattern" ])

    travel_to(Time.utc(2026, 7, 13, 15, 0)) do
      run_batch_and_its_jobs
      exercise = DailyExercise.find_by(user: user, date: Date.current)
      expect(exercise.dropped_sections).to eq([ "pattern" ])
    end
  end

  it "judges an on-demand generation on a weekday" do
    user.update!(language: "javascript")
    svc = stub_provider(dropped: [ "pattern" ])

    travel_to(Time.utc(2026, 7, 13, 6, 0)) do
      described_class.new.perform(user_id: user.id)

      expect(svc).to have_received(:generate_judged_exercise).with(user, language: "javascript", schedule_context: hash_including(active: true))
      expect(DailyExercise.find_by(user: user, date: Date.current).dropped_sections).to eq([ "pattern" ])
    end
  end

  it "judges an on-demand generation on a weekend too, since its code review is a bug hunt" do
    user.update!(language: "javascript")
    svc = stub_provider(dropped: [ "design_comparison" ])

    travel_to(Time.utc(2026, 7, 18, 12, 0)) do
      described_class.new.perform(user_id: user.id)

      expect(svc).to have_received(:generate_judged_exercise).with(user, language: "javascript", schedule_context: hash_including(active: true))
      expect(DailyExercise.find_by(user: user, date: Date.current).dropped_sections).to eq([ "design_comparison" ])
    end
  end

  it "dates the set by the day it was planned for, when the judged run crosses midnight" do
    svc = stub_provider
    allow(svc).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:|
      result = AiService::JudgedSet.new(problem_set: { "code_review" => {} }, dropped_sections: [], outcomes: {}, plan_notes: {})
      judged = with_practice_context(result, user: caller, language: language, schedule_context: schedule_context)
      travel(30.minutes)
      judged
    end

    travel_to(Time.utc(2026, 10, 18, 23, 40)) { described_class.new.perform(user_id: user.id) }

    expect(DailyExercise.where(user: user).pluck(:date)).to eq([ Date.new(2026, 10, 18) ])
  end

  it "skips an anonymized user on the on-demand path" do
    user.anonymize!
    expect(AiService).not_to receive(:for)

    described_class.new.perform(user_id: user.id)

    expect(DailyExercise.exists?(user: user, date: Date.current)).to be false
  end

  describe "hourly batch (no user_id), zone-gated" do
    def stub_generation_for(u)
      stub_provider(u)
    end

    let(:pac) { User.create!(email: "pac@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles") }

    it "does not generate before 8am local" do
      stub_generation_for(pac)
      travel_to(Time.utc(2026, 7, 13, 14, 0)) do
        run_batch_and_its_jobs
        local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: local_today)).to be false
      end
    end

    it "generates at/after 8am local on a weekday" do
      stub_generation_for(pac)
      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        run_batch_and_its_jobs
        local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: local_today)).to be true
      end
    end

    it "does not generate on a local weekend" do
      stub_generation_for(pac)
      travel_to(Time.utc(2026, 7, 18, 17, 0)) do
        run_batch_and_its_jobs
        expect(DailyExercise.where(user: pac).count).to eq(0)
      end
    end

    it "creates exactly one exercise when the batch runs twice in the same hour" do
      stub_generation_for(pac)
      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        run_batch_and_its_jobs
        run_batch_and_its_jobs
        expect(DailyExercise.where(user: pac).count).to eq(1)
      end
    end

    it "gates each user independently by their own zone within the same batch run" do
      alaska = User.create!(email: "alaska@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Anchorage")
      stub_generation_for(pac)
      stub_generation_for(alaska)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        run_batch_and_its_jobs

        pac_local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: pac_local_today)).to be true

        expect(DailyExercise.where(user: alaska).count).to eq(0)
      end
    end

    it "logs any error one account raises and still enqueues the users after it" do
      broken = User.create!(email: "broken@example.com", provider: "anthropic",
                            api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles")
      allow(described_class).to receive(:perform_later).and_call_original
      allow(described_class).to receive(:perform_later).with(user_id: broken.id, remind: true).and_raise(RuntimeError, "unexpected")
      allow(Rails.logger).to receive(:error)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }.to have_enqueued_job(described_class).with(user_id: pac.id, remind: true).once
      end
      expect(Rails.logger).to have_received(:error).with("Generation batch skipped user #{broken.id}: RuntimeError: unexpected")
    end

    it "carries on when Solid Queue discards an enqueue for a user already in progress" do
      busy = User.create!(email: "busy@example.com", provider: "anthropic",
                          api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles")
      allow(described_class).to receive(:perform_later).and_call_original
      allow(described_class).to receive(:perform_later).with(user_id: busy.id, remind: true).and_return(false)
      expect(Rails.logger).not_to receive(:error)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }.to have_enqueued_job(described_class).with(user_id: pac.id, remind: true).once
      end
    end

    it "enqueues one batch-started job for a due user and calls no provider itself" do
      service = stub_generation_for(pac)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }.to have_enqueued_job(described_class).with(user_id: pac.id, remind: true).once
      end
      expect(service).not_to have_received(:generate_judged_exercise)
      expect(DailyExercise.where(user: pac).count).to eq(0)
    end

    it "enqueues nothing before 8am local or on a local weekend" do
      pac

      [ Time.utc(2026, 7, 13, 14, 0), Time.utc(2026, 7, 18, 17, 0) ].each do |moment|
        travel_to(moment) { expect { described_class.new.perform }.not_to have_enqueued_job(described_class) }
      end
    end

    it "enqueues nothing for a user who has today's set, and still checks whether a nudge is due" do
      pac.update!(reminder_level: :ready_and_nudges)

      travel_to(Time.utc(2026, 7, 13, 21, 0)) do
        Time.use_zone(pac.effective_time_zone) do
          DailyExercise.create!(user: pac, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                                problem_set: { "code_review" => { "question" => "q" } })
        end

        expect { described_class.new.perform }
          .to have_enqueued_job(SendPushReminderJob).with(user_id: pac.id, kind: :nudge)
          .and have_enqueued_job(described_class).exactly(0).times
      end
    end

    it "skips a user who has paused automatic generation" do
      stub_generation_for(pac)
      pac.update!(paused_generation_at: Time.current)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        run_batch_and_its_jobs
        local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: local_today)).to be false
      end
    end

    it "still generates for a paused user on the on-demand path" do
      stub_generation_for(pac)
      pac.update!(paused_generation_at: Time.current)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        described_class.new.perform(user_id: pac.id)
        local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: local_today)).to be true
      end
    end
  end

  describe "the push reminder" do
    def stub_generation_for(u)
      stub_provider(u)
    end

    let(:pac) { User.create!(email: "reminded@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles") }

    it "enqueues one for the batch that generated the set" do
      stub_generation_for(pac)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { run_batch_and_its_jobs }
          .to have_enqueued_job(SendPushReminderJob).with(user_id: pac.id).once
      end
    end

    # The cron runs hourly, so a check only inside generate_now would let later runs re-enqueue the nudge.
    it "does not enqueue again on later runs the same day" do
      stub_generation_for(pac)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) { run_batch_and_its_jobs }

      travel_to(Time.utc(2026, 7, 13, 16, 0)) do
        expect { run_batch_and_its_jobs }.not_to have_enqueued_job(SendPushReminderJob)
      end
    end

    it "does not enqueue for an on-demand generation" do
      stub_generation_for(pac)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform(user_id: pac.id) }.not_to have_enqueued_job(SendPushReminderJob)
      end
    end

    it "does not enqueue when the provider failed and no set exists" do
      svc = instance_double(ClaudeService)
      allow(svc).to receive(:generate_judged_exercise).and_raise(ProviderError, "boom")
      allow(AiService).to receive(:for).with(pac).and_return(svc)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { run_batch_and_its_jobs }.not_to have_enqueued_job(SendPushReminderJob)
      end
    end

    it "enqueues one for a batch-started job that generates the set" do
      stub_generation_for(pac)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform(user_id: pac.id, remind: true) }
          .to have_enqueued_job(SendPushReminderJob).with(user_id: pac.id).once
      end
    end

    it "records a batch-started job's provider failure as today's and enqueues none" do
      stub_provider_failure(ProviderError::RateLimitError, "rate limited", pac)
      allow(Rails.logger).to receive(:error)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform(user_id: pac.id, remind: true) }.not_to have_enqueued_job(SendPushReminderJob)

        expect(pac.reload).to have_attributes(last_generation_failure: "short_rate_limit", last_generation_error_date: Date.new(2026, 7, 13))
      end
    end
  end

  describe "a batch-started job that runs after its set stopped being due" do
    let(:pac) { User.create!(email: "late@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles") }
    let!(:service) { stub_provider(pac) }

    def expect_nothing_generated
      expect { described_class.new.perform(user_id: pac.id, remind: true) }.not_to have_enqueued_job(SendPushReminderJob)
      expect(service).not_to have_received(:generate_judged_exercise)
      expect(DailyExercise.where(user: pac).count).to eq(0)
    end

    it "generates nothing once midnight has moved the user into Saturday" do
      travel_to(Time.utc(2026, 7, 18, 7, 30)) { expect_nothing_generated }
    end

    it "generates nothing before 8am in the user's zone" do
      travel_to(Time.utc(2026, 7, 13, 14, 0)) { expect_nothing_generated }
    end

    it "generates nothing more when another job already wrote today's set" do
      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        Time.use_zone(pac.effective_time_zone) do
          DailyExercise.create!(user: pac, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                                problem_set: { "code_review" => {} })
        end

        expect { described_class.new.perform(user_id: pac.id, remind: true) }.not_to have_enqueued_job(SendPushReminderJob)
        expect(service).not_to have_received(:generate_judged_exercise)
      end
    end

    it "generates nothing for a user who paused after the batch enqueued the job" do
      pac.update!(paused_generation_at: Time.current)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) { expect_nothing_generated }
    end
  end

  describe "a batch run while a generation for the same user is in progress" do
    let(:pac) { User.create!(email: "inflight@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles") }

    around do |example|
      adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :solid_queue
      example.run
    ensure
      ActiveJob::Base.queue_adapter = adapter
    end

    let(:worker) do
      SolidQueue::Process.create!(kind: "Worker", name: SecureRandom.uuid, pid: Process.pid,
                                 hostname: "localhost", last_heartbeat_at: Time.current)
    end

    def queued_generations = SolidQueue::Job.where(class_name: described_class.name)

    def perform_ready_jobs
      SolidQueue::ReadyExecution.claim("*", 10, worker.id).each(&:perform)
    end

    def stub_provider_that_runs_a_batch_mid_call(user)
      calls = 0
      service = stub_provider(user)
      allow(service).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:|
        calls += 1
        yield if calls == 1
        judged = AiService::JudgedSet.new(problem_set: { "code_review" => {} }, dropped_sections: [], outcomes: {}, plan_notes: {})
        with_practice_context(judged, user: caller, language: language, schedule_context: schedule_context)
      end
      -> { calls }
    end

    it "makes no second provider call for that user" do
      added_by_batch = nil
      calls = stub_provider_that_runs_a_batch_mid_call(pac) do
        before_batch = queued_generations.count
        described_class.new.perform
        added_by_batch = queued_generations.count - before_batch
      end

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        described_class.perform_later(user_id: pac.id)
        perform_ready_jobs
        perform_ready_jobs
      end

      expect(calls.call).to eq(1)
      expect(added_by_batch).to eq(0)
      expect(SolidQueue::FailedExecution.count).to eq(0)
      expect(DailyExercise.where(user: pac).count).to eq(1)
    end

    it "enqueues the user once the permit is free, which is what the example above would do without it" do
      stub_provider(pac)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }.to change { queued_generations.count }.by(1)
      end
    end
  end

  describe "the unfinished-set nudge on a later tick" do
    it "nudges when the set exists and nothing has been answered" do
      user.update!(reminder_level: :ready_and_nudges)

      Time.use_zone("UTC") do
        travel_to(Time.zone.local(2026, 9, 8, 14, 0)) do
          DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                language: "ruby_rails",
                                problem_set: { "code_review" => { "question" => "q" } })

          expect(SendPushReminderJob).to receive(:perform_later).with(user_id: user.id, kind: :nudge)

          described_class.new.perform
        end
      end
    end

    it "nudges a day that was answered in part and then left alone" do
      user.update!(reminder_level: :ready_and_nudges)

      Time.use_zone("UTC") do
        travel_to(Time.zone.local(2026, 9, 8, 11, 0)) do
          exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                           language: "ruby_rails",
                                           problem_set: { "code_review" => { "question" => "q" },
                                                          "pattern"     => { "question" => "p" } })
          DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                answers: { "code_review" => "a genuinely substantive answer here" })
        end

        travel_to(Time.zone.local(2026, 9, 8, 14, 0)) do
          expect(SendPushReminderJob).to receive(:perform_later).with(user_id: user.id, kind: :nudge)

          described_class.new.perform
        end
      end
    end

    it "goes quiet while the answers are still being saved" do
      user.update!(reminder_level: :ready_and_nudges)

      Time.use_zone("UTC") do
        travel_to(Time.zone.local(2026, 9, 8, 14, 0)) do
          exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                           language: "ruby_rails",
                                           problem_set: { "code_review" => { "question" => "q" } })
          DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                answers: { "code_review" => "a genuinely substantive answer here" })

          expect(SendPushReminderJob).not_to receive(:perform_later)

          described_class.new.perform
        end
      end
    end

    it "goes quiet once the day is submitted" do
      user.update!(reminder_level: :ready_and_nudges)

      Time.use_zone("UTC") do
        travel_to(Time.zone.local(2026, 9, 8, 11, 0)) do
          exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                           language: "ruby_rails",
                                           problem_set: { "code_review" => { "question" => "q" } })
          DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                answers: { "code_review" => "a genuinely substantive answer here" },
                                submitted_at: Time.current)
        end

        travel_to(Time.zone.local(2026, 9, 8, 14, 0)) do
          expect(SendPushReminderJob).not_to receive(:perform_later)

          described_class.new.perform
        end
      end
    end

    it "does not regenerate the set it nudges about" do
      user.update!(reminder_level: :ready_and_nudges)

      Time.use_zone("UTC") do
        travel_to(Time.zone.local(2026, 9, 8, 14, 0)) do
          DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                language: "ruby_rails",
                                problem_set: { "code_review" => { "question" => "q" } })
          allow(SendPushReminderJob).to receive(:perform_later)

          described_class.new.perform

          expect(DailyExercise.where(user: user, date: Date.current).count).to eq(1)
        end
      end
    end
  end

  describe "the judge's solves" do
    let(:solves) { [ live_solve(shipped: false, never_shown_reason: "replaced_by_retry"), live_solve(attempt: 1) ] }
    let(:logged) { StringIO.new }

    def stub_judged(solves)
      svc = stub_provider(solves: solves)
      allow(svc).to receive(:model_for).with("generate_exercise").and_return("claude-opus-5-5")
      svc
    end

    it "writes them with the row, as live records of that set, naming the model that drafted it" do
      stub_judged(solves)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) { described_class.new.perform(user_id: user.id) }

      exercise = DailyExercise.find_by!(user: user, date: Date.new(2026, 7, 13))
      records = exercise.judge_solves.order(:attempt)
      expect(records.map { |record| [ record.attempt, record.shipped, record.never_shown_reason ] })
        .to eq([ [ 0, false, "replaced_by_retry" ], [ 1, true, nil ] ])
      expect(records).to all(have_attributes(source: "live", user_id: user.id, set_generated_at: exercise.generated_at,
                                             draft_model: "claude-opus-5-5", judge_model: "claude-sonnet-5-5"))
    end

    it "writes them for a weekend set too, which is judged like a weekday's" do
      svc = stub_judged(solves)

      travel_to(Time.utc(2026, 7, 18, 15, 0)) { described_class.new.perform(user_id: user.id) }

      expect(svc).to have_received(:generate_judged_exercise)
      expect(DailyExercise.find_by!(user: user, date: Date.new(2026, 7, 18)).judge_solves.count).to eq(solves.size)
    end

    it "keeps the set when a record is refused, and logs the refusal without the section or its key" do
      stub_judged([ live_solve, live_solve(attempt: 1, revert_reason: "solve_mismatch") ])
      allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(logged))

      travel_to(Time.utc(2026, 7, 13, 15, 0)) { described_class.new.perform(user_id: user.id) }

      exercise = DailyExercise.find_by!(user: user, date: Date.new(2026, 7, 13))
      expect(JudgeSolve.count).to eq(0)
      expect(logged.string).to include("[judge_solves_record_failed] user=#{user.id} exercise=#{exercise.id} reason=")
      expect(logged.string).not_to include("SECRET", "Which fits?", "a = 1")
      expect(user.reload.last_generation_error).to be_nil
    end
  end
end
