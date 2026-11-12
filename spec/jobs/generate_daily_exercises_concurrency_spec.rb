require "rails_helper"

RSpec.describe GenerateDailyExercisesJob do
  include ActiveSupport::Testing::TimeHelpers
  include ActiveJob::TestHelper
  include PracticeGenerationHelpers

  let(:weekday_morning) { Time.utc(2026, 7, 13, 15, 0) }
  let(:budget) { CallProfiles::JUDGED_GENERATION_BUDGET.seconds }

  def create_user(name, **attributes)
    User.create!(email: "#{name}-#{SecureRandom.hex(4)}@example.com", provider: "anthropic",
                 api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles", **attributes)
  end

  def judged_set(caller, language, schedule_context)
    judged = AiService::JudgedSet.new(problem_set: { "code_review" => {} }, dropped_sections: [], outcomes: {}, plan_notes: {})
    with_practice_context(judged, user: caller, language: language, schedule_context: schedule_context)
  end

  def stub_provider(user, &during_call)
    calls = []
    service = instance_double(ClaudeService)
    allow(service).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:|
      calls << caller.id
      during_call&.call(caller)
      judged_set(caller, language, schedule_context)
    end
    allow(AiService).to receive(:for).with(user).and_return(service)
    calls
  end

  def held_by_another_job(user) = User.find(user.id).claim_generating!

  describe "while another generation holds the user's claim" do
    let(:user) { create_user("held") }
    let!(:calls) { stub_provider(user) }

    around { |example| travel_to(weekday_morning) { example.run } }

    it "makes no provider call for a second dashboard job" do
      held_by_another_job(user)

      described_class.perform_now(user_id: user.id)

      expect(calls).to eq([])
      expect(user.daily_exercises.count).to eq(0)
    end

    it "makes no provider call for a scheduled job, and sends no reminder" do
      held_by_another_job(user)

      expect { described_class.perform_now(user_id: user.id, scheduled: true) }.not_to have_enqueued_job(SendPushReminderJob)
      expect(calls).to eq([])
    end

    it "writes no failure, logs one line and leaves the other job's claim in place" do
      token = held_by_another_job(user)
      allow(Rails.logger).to receive(:info)

      expect { described_class.perform_now(user_id: user.id) }.not_to raise_error

      expect(Rails.logger).to have_received(:info).with("Skipped generation for user #{user.id}: another generation holds the claim").once
      expect(user.reload).to have_attributes(generating_since: token, last_generation_error_date: nil,
                                             last_generation_error: nil, last_generation_failure: nil)
    end

    it "lets a different user generate at the same time" do
      other = create_user("other")
      other_calls = stub_provider(other)
      held_by_another_job(user)

      described_class.perform_now(user_id: other.id)

      expect(other_calls).to eq([ other.id ])
      expect(other.daily_exercises.count).to eq(1)
    end

    it "holds until the judged generation budget has passed, then lets a job take a crashed worker's claim" do
      held_by_another_job(user)

      travel budget - 1.minute
      described_class.perform_now(user_id: user.id)
      expect(calls).to eq([])

      travel 2.minutes
      described_class.perform_now(user_id: user.id)
      expect(calls).to eq([ user.id ])
      expect(user.reload.generating_since).to be_nil
    end
  end

  describe "taking and releasing the claim" do
    let(:user) { create_user("claims") }

    around { |example| travel_to(weekday_morning) { example.run } }

    def stub_failure(error)
      service = instance_double(ClaudeService)
      allow(service).to receive(:generate_judged_exercise).and_raise(error)
      allow(AiService).to receive(:for).with(user).and_return(service)
      allow(Rails.logger).to receive(:error)
    end

    it "holds the claim during the provider call and releases it once the set is written" do
      held_during_call = nil
      stub_provider(user) { |caller| held_during_call = User.find(caller.id).generating? }

      described_class.perform_now(user_id: user.id)

      expect(held_during_call).to be(true)
      expect(user.reload).to have_attributes(generating_since: nil)
      expect(user.daily_exercises.count).to eq(1)
    end

    it "releases the claim after a provider error" do
      stub_failure(ProviderError.new("boom"))

      described_class.perform_now(user_id: user.id)

      expect(user.reload).to have_attributes(generating_since: nil, last_generation_error_date: Date.current)
    end

    it "releases the claim after an error it does not handle" do
      stub_failure(NoMethodError.new("unexpected"))

      expect { described_class.new.perform(user_id: user.id) }.to raise_error(NoMethodError)

      expect(user.reload.generating_since).to be_nil
    end

    it "releases the claim when the commit is superseded" do
      stub_provider(user) { |caller| User.find(caller.id).update!(daily_section_count: 2) }

      described_class.perform_now(user_id: user.id)

      expect(user.reload).to have_attributes(generating_since: nil, last_generation_error_date: Date.current)
      expect(user.daily_exercises.count).to eq(0)
    end

    it "releases the claim when it finds today's set already written" do
      DailyExercise.create!(user: user, date: Time.use_zone(user.effective_time_zone) { Date.current },
                            generated_at: Time.current, language: "ruby_rails", problem_set: { "code_review" => {} })
      calls = stub_provider(user)

      described_class.perform_now(user_id: user.id)

      expect(calls).to eq([])
      expect(user.reload.generating_since).to be_nil
    end

    # A job that overran the budget can find its claim taken over; its failure would sit above the newer job's set.
    it "writes no failure and leaves the newer claim alone when its own claim was taken over mid-call" do
      takeover = nil
      service = instance_double(ClaudeService)
      allow(service).to receive(:generate_judged_exercise) do |caller, **|
        travel budget + 1.minute
        takeover = held_by_another_job(caller)
        raise ProviderError, "boom"
      end
      allow(AiService).to receive(:for).with(user).and_return(service)
      allow(Rails.logger).to receive(:error)

      described_class.perform_now(user_id: user.id)

      expect(takeover).to be_present
      expect(user.reload).to have_attributes(generating_since: takeover, last_generation_error_date: nil)
    end
  end

  describe "jobs in the Solid Queue tables" do
    let(:user) { create_user("queued") }
    let(:worker) do
      SolidQueue::Process.create!(kind: "Worker", name: SecureRandom.uuid, pid: Process.pid,
                                 hostname: "localhost", last_heartbeat_at: Time.current)
    end

    around do |example|
      adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :solid_queue
      travel_to(weekday_morning) { example.run }
    ensure
      ActiveJob::Base.queue_adapter = adapter
    end

    def queued(job_class = described_class) = SolidQueue::Job.where(class_name: job_class.name)

    def perform_next_job = SolidQueue::ReadyExecution.claim("provider_calls", 1, worker.id).each(&:perform)

    def perform_every_job
      nil while perform_next_job.any?
    end

    def arguments_of(job) = job.arguments.fetch("arguments").first.except("_aj_ruby2_keywords")

    def enqueue(**arguments) = described_class.perform_later(**arguments)

    def enqueue_scheduled(account = user) = enqueue(user_id: account.id, scheduled: true)

    it "discards a second click for a user while the first click's job is queued, without raising" do
      enqueue(user_id: user.id)
      second = described_class.new(user_id: user.id)

      expect { SolidQueue::Job.enqueue(second) }.not_to change { queued.count }
      expect(second.successfully_enqueued?).to be(false)
      expect(SolidQueue::BlockedExecution.count).to eq(0)
    end

    it "discards a second click for a user while the first click's job is running" do
      added_mid_call = nil
      stub_provider(user) do
        before = queued.count
        enqueue(user_id: user.id)
        added_mid_call = queued.count - before
      end

      enqueue(user_id: user.id)
      perform_every_job

      expect(added_mid_call).to eq(0)
      expect(user.daily_exercises.count).to eq(1)
    end

    it "discards a second scheduled job for a user while one is queued, so two hand-out runs leave one" do
      user

      expect { 2.times { EnqueueDueGenerationsJob.perform_now } }.to change { queued.count }.by(1)
      expect(SolidQueue::BlockedExecution.count).to eq(0)
    end

    it "discards a second scheduled job for a user while one is running" do
      added_mid_call = nil
      stub_provider(user) do
        before = queued.count
        EnqueueDueGenerationsJob.perform_now
        added_mid_call = queued.count - before
      end

      enqueue_scheduled
      perform_every_job

      expect(added_mid_call).to eq(0)
    end

    it "keeps a click when the user's scheduled job is queued, and a scheduled job when a click is queued" do
      enqueue_scheduled
      expect { enqueue(user_id: user.id) }.to change { queued.count }.by(1)

      other = create_user("other")
      enqueue(user_id: other.id)
      expect { enqueue_scheduled(other) }.to change { queued.count }.by(1)
    end

    it "keeps a click made while the user's scheduled job is running, and the claim stops it calling a provider" do
      added_mid_call = nil
      calls = stub_provider(user) do
        before = queued.count
        enqueue(user_id: user.id)
        added_mid_call = queued.count - before
        perform_next_job
      end

      enqueue_scheduled
      perform_every_job

      expect(added_mid_call).to eq(1)
      expect(calls).to eq([ user.id ])
      expect(SolidQueue::FailedExecution.count).to eq(0)
    end

    it "lets different users queue the same kind of job" do
      other = create_user("other")
      enqueue(user_id: user.id)
      enqueue_scheduled

      expect { enqueue(user_id: other.id) }.to change { queued.count }.by(1)
      expect { enqueue_scheduled(other) }.to change { queued.count }.by(1)
    end

    it "holds each permit for the judged generation budget" do
      expect(described_class.concurrency_duration).to be >= budget
      expect(described_class.new(user_id: user.id).concurrency_key).not_to eq(described_class.new(user_id: user.id, scheduled: true).concurrency_key)
    end

    # The permit counts from the enqueue and the claim from the start of the run, so the claim outlasts it.
    it "lets a duplicate be queued once the permit has expired, and the claim stops it calling a provider" do
      added_after_expiry = nil
      calls = stub_provider(user) do
        travel budget - 5.minutes
        SolidQueue::Dispatcher::ConcurrencyMaintenance.new(1, 100).send(:expire_semaphores)
        before = queued.count
        enqueue(user_id: user.id)
        added_after_expiry = queued.count - before
        perform_next_job
      end

      enqueue(user_id: user.id)
      travel 10.minutes
      perform_every_job

      expect(added_after_expiry).to eq(1)
      expect(calls).to eq([ user.id ])
      expect(user.daily_exercises.count).to eq(1)
    end

    it "never limits a no-argument job left by the release before the hand-out job" do
      expect(described_class.new.concurrency_limited?).to be(false)
      expect { 2.times { enqueue } }.to change { queued.count }.by(2)
    end

    it "puts no limit on the hand-out job itself" do
      expect(EnqueueDueGenerationsJob.new.concurrency_limited?).to be(false)
    end

    it "runs a dashboard click ahead of the scheduled job queued before it, and the click generates" do
      calls = stub_provider(user)
      EnqueueDueGenerationsJob.perform_now

      expect { described_class.perform_later(user_id: user.id) }.to change { queued.count }.by(1)
      perform_next_job

      expect(queued.where.not(finished_at: nil).map { |job| arguments_of(job) }).to eq([ { "user_id" => user.id } ])
      expect(calls).to eq([ user.id ])
      expect(user.daily_exercises.count).to eq(1)
      expect(queued(SendPushReminderJob).count).to eq(0)
    end

    it "makes one provider call when the scheduled job then runs behind the click" do
      calls = stub_provider(user)
      EnqueueDueGenerationsJob.perform_now
      described_class.perform_later(user_id: user.id)

      perform_every_job

      expect(calls).to eq([ user.id ])
      expect(user.daily_exercises.count).to eq(1)
      expect(SolidQueue::FailedExecution.count).to eq(0)
    end

    it "generates for a user who paused and clicked generate anyway while their scheduled job was queued" do
      calls = stub_provider(user)
      EnqueueDueGenerationsJob.perform_now
      user.update!(paused_generation_at: Time.current)

      expect { described_class.perform_later(user_id: user.id) }.to change { queued.count }.by(1)
      perform_every_job

      expect(calls).to eq([ user.id ])
      expect(user.daily_exercises.count).to eq(1)
      expect(SolidQueue::FailedExecution.count).to eq(0)
    end

    it "makes one provider call when two hand-out runs find the same user due" do
      calls = stub_provider(user)

      expect { 2.times { EnqueueDueGenerationsJob.perform_now } }.to change { queued.count }.by(1)
      perform_every_job

      expect(calls).to eq([ user.id ])
      expect(user.daily_exercises.count).to eq(1)
    end

    it "makes no second provider call when a hand-out run's job starts while the first is mid-call" do
      calls = stub_provider(user) do
        EnqueueDueGenerationsJob.perform_now
        perform_next_job
      end

      described_class.perform_later(user_id: user.id)
      perform_every_job

      expect(calls).to eq([ user.id ])
      expect(queued.where.not(finished_at: nil).count).to eq(2)
      expect(SolidQueue::FailedExecution.count).to eq(0)
      expect(user.daily_exercises.count).to eq(1)
    end
  end

  describe "two workers racing for one user's claim" do
    self.use_transactional_tests = false

    let!(:user) { create_user("race") }

    after { user.destroy! }

    def connected(&work)
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { work.call } }
    end

    def await(queue) = Timeout.timeout(10) { queue.pop }

    it "lets exactly one of them take it" do
      start = Queue.new
      racers = Array.new(4) { connected { await(start) && User.find(user.id).claim_generating! } }
      racers.size.times { start << true }

      expect(racers.map(&:value).compact.size).to eq(1)
    end

    it "makes one provider call when a second job runs while the first is mid-call" do
      in_call, finish = Queue.new, Queue.new
      calls = stub_provider(user) do
        in_call << true
        await(finish)
      end

      first = connected { described_class.perform_now(user_id: user.id) }
      await(in_call)
      described_class.perform_now(user_id: user.id)
      finish << true
      first.join

      expect(calls).to eq([ user.id ])
      expect(user.reload.generating_since).to be_nil
      expect(user.daily_exercises.count).to eq(1)
    ensure
      finish << true if finish
      first&.join
    end
  end
end
