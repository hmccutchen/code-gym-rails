require "rails_helper"

RSpec.describe "A worker claiming a job while its account is deleted", type: :model do
  self.use_transactional_tests = false

  let!(:user) { create_user_with_key(email: "job-claim-#{SecureRandom.hex(8)}@example.com") }
  let!(:process) do
    SolidQueue::Process.create!(kind: "Worker", last_heartbeat_at: Time.current, pid: 1, hostname: "spec", name: "worker-#{SecureRandom.hex(4)}")
  end
  let!(:job) do
    queued = GenerateDailyExercisesJob.new(user_id: user.id)
    SolidQueue::Job.create!(queue_name: "claim-#{SecureRandom.hex(4)}", class_name: queued.class.name,
                            arguments: queued.serialize, active_job_id: queued.job_id, priority: 0)
  end

  after do
    SolidQueue::Job.where(id: job.id).delete_all
    process.delete
    AccountDeletion.call(user)
  end

  def claim_in_another_connection(hold_open: nil)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SolidQueue::ReadyExecution.transaction do
          SolidQueue::ReadyExecution.claim([ job.queue_name ], 1, process.id).tap { hold_open&.call }
        end
      end
    end
  end

  def still_running?
    SolidQueue::Job.exists?(job.id) && SolidQueue::ClaimedExecution.exists?(job_id: job.id, process_id: process.id)
  end

  it "leaves a job alone when a worker claims it between the scan and the delete" do
    claimed = nil
    allow(UnfinishedJobs).to receive(:names?).and_wrap_original do |original, *args|
      claimed ||= claim_in_another_connection.value
      original.call(*args)
    end

    AccountDeletion.call(user)

    expect(claimed.map(&:job_id)).to eq([ job.id ])
    expect(still_running?).to be(true)
  end

  it "leaves a job alone, without waiting, while a worker's claim is still open" do
    claim_open = Queue.new
    release = Queue.new
    worker = claim_in_another_connection(hold_open: lambda do
      claim_open << true
      release.pop(timeout: 3)
    end)
    claim_open.pop

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    AccountDeletion.call(user)
    waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    release << true

    expect(worker.value.map(&:job_id)).to eq([ job.id ])
    expect(waited).to be < 2
    expect(still_running?).to be(true)
  end

  it "still deletes a job no worker has claimed" do
    AccountDeletion.call(user)

    expect(SolidQueue::Job.exists?(job.id)).to be(false)
  end
end
