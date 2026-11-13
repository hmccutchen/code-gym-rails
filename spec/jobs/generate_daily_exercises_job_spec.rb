require "rails_helper"

RSpec.describe GenerateDailyExercisesJob do
  include ActiveSupport::Testing::TimeHelpers
  include ActiveJob::TestHelper
  include PracticeGenerationHelpers
  include SolidQueueOrderHelpers

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
    EnqueueDueGenerationsJob.new.perform
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

  describe "concept write-ups for the new set" do
    let(:tagged_set) do
      { "code_review" => { "question" => "q", "concept" => "n_plus_one" },
        "design_comparison" => { "question" => "q", "concept" => "memoization" } }
    end

    it "queues the user's missing write-ups at background priority once the set is saved" do
      ConceptReference.create!(user: user, concept: "memoization", language: "ruby_rails", tagline: "shared")
      stub_provider(problem_set: tagged_set)

      described_class.new.perform(user_id: user.id)

      expect(user.daily_exercises.count).to eq(1)
      queued = enqueued_jobs.select { |job| job["job_class"] == "GenerateConceptReferenceJob" }
      expect(queued.map { |job| job["arguments"].first.slice("concept", "language", "user_id") })
        .to eq([ { "concept" => "n_plus_one", "language" => "ruby_rails", "user_id" => user.id } ])
      expect(queued.sole["priority"]).to eq(JobPriority::BACKGROUND)
    end

    it "leaves its write-ups behind a scheduled set the hand-out enqueues later, in Solid Queue's claim order" do
      stub_provider(problem_set: tagged_set)
      described_class.new.perform(user_id: user.id)
      teammate = User.create!(email: "teammate@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" })
      described_class.set(priority: JobPriority::SCHEDULED).perform_later(user_id: teammate.id, scheduled: true)

      move_to_solid_queue(ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job["queue_name"] == "provider_calls" })

      expect(solid_queue_claim_order("provider_calls"))
        .to eq(%w[GenerateDailyExercisesJob GenerateConceptReferenceJob GenerateConceptReferenceJob])
    end

    it "queues none for a concept the set hides until it is submitted" do
      stub_provider(problem_set: { "code_review" => { "question" => "q", "concept" => "n_plus_one", "purpose" => "Find the trap." } })

      expect { described_class.new.perform(user_id: user.id) }.not_to have_enqueued_job(GenerateConceptReferenceJob)
    end

    it "queues none when no set is saved" do
      existing = user.daily_exercises.create!(date: Date.current, language: "ruby_rails",
                                                               problem_set: tagged_set, generated_at: Time.current)
      stub_provider(problem_set: tagged_set)

      expect { described_class.new.perform(user_id: user.id) }.not_to have_enqueued_job(GenerateConceptReferenceJob)
      expect(existing.reload).to be_persisted
    end
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

  def stub_failure_after_another_job_wrote_the_set
    svc = instance_double(ClaudeService)
    allow(svc).to receive(:generate_judged_exercise) do
      DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} },
                            generated_at: Time.current, language: "ruby_rails")
      raise ProviderError, "boom"
    end
    allow(AiService).to receive(:for).with(user).and_return(svc)
    allow(Rails.logger).to receive(:error)
  end

  # A failure banner above a set a concurrent generation already created would stay all day.
  it "does not persist a failure when today's exercise appeared during the call" do
    stub_failure_after_another_job_wrote_the_set

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error_date).to be_nil
    expect(user.last_generation_error).to be_nil
  end

  it "clears a stale failure flag when today's exercise appeared during the call" do
    user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
    stub_failure_after_another_job_wrote_the_set

    described_class.new.perform(user_id: user.id)

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

  describe "a job left in the queue by the release that ran the hourly batch in this class" do
    it "hands a no-argument job to the hand-out job, without raising or calling a provider" do
      expect(AiService).not_to receive(:for)

      expect { described_class.perform_now }.to have_enqueued_job(EnqueueDueGenerationsJob).once
    end

    it "still generates for a job enqueued with a user and no other argument" do
      stub_provider

      described_class.perform_now(user_id: user.id)

      expect(DailyExercise.exists?(user: user, date: Date.current)).to be true
    end
  end

  describe "the hourly hand-out and the jobs it starts, zone-gated" do
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

    it "enqueues one for a scheduled job that generates the set" do
      stub_generation_for(pac)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform(user_id: pac.id, scheduled: true) }
          .to have_enqueued_job(SendPushReminderJob).with(user_id: pac.id).once
      end
    end

    it "still enqueues one, and finishes cleanly, when queueing the set's write-ups fails after the set is saved" do
      stub_provider(pac, problem_set: { "code_review" => { "question" => "q", "concept" => "n_plus_one" } })
      allow(GenerateConceptReferenceJob.queue_adapter).to receive(:enqueue).and_wrap_original do |enqueue, job|
        raise SolidQueue::Job::EnqueueError, "PG::ConnectionBad" if job.is_a?(GenerateConceptReferenceJob)

        enqueue.call(job)
      end
      allow(Rails.logger).to receive(:error)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform(user_id: pac.id, scheduled: true) }
          .to have_enqueued_job(SendPushReminderJob).with(user_id: pac.id).once
      end
      expect(pac.daily_exercises.count).to eq(1)
      expect(Rails.logger).to have_received(:error).with(/Could not queue concept write-ups for user #{pac.id}.*PG::ConnectionBad/)
    end

    it "records a scheduled job's provider failure as today's and enqueues none" do
      stub_provider_failure(ProviderError::RateLimitError, "rate limited", pac)
      allow(Rails.logger).to receive(:error)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform(user_id: pac.id, scheduled: true) }.not_to have_enqueued_job(SendPushReminderJob)

        expect(pac.reload).to have_attributes(last_generation_failure: "short_rate_limit", last_generation_error_date: Date.new(2026, 7, 13))
      end
    end
  end

  describe "a scheduled job that runs after its set stopped being due" do
    let(:pac) { User.create!(email: "late@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles") }
    let!(:service) { stub_provider(pac) }

    def expect_nothing_generated
      expect { described_class.new.perform(user_id: pac.id, scheduled: true) }.not_to have_enqueued_job(SendPushReminderJob)
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

        expect { described_class.new.perform(user_id: pac.id, scheduled: true) }.not_to have_enqueued_job(SendPushReminderJob)
        expect(service).not_to have_received(:generate_judged_exercise)
      end
    end

    it "generates nothing for a user who paused after the hand-out enqueued the job" do
      pac.update!(paused_generation_at: Time.current)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) { expect_nothing_generated }
    end

    it "generates nothing for a user who removed their key or deleted their account after the hand-out" do
      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        pac.update!(provider: nil, api_keys: nil)
        expect_nothing_generated

        pac.anonymize!
        expect_nothing_generated
      end
    end

    it "leaves no claim behind when it generates nothing" do
      travel_to(Time.utc(2026, 7, 13, 14, 0)) { expect_nothing_generated }

      expect(pac.reload.generating_since).to be_nil
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
