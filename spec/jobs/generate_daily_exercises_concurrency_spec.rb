require "rails_helper"

RSpec.describe GenerateDailyExercisesJob do
  def enqueue(**args) = SolidQueue::Job.enqueue(described_class.new(**args))

  it "discards a second on-demand generation for a user while the first holds the permit" do
    enqueue(user_id: 1)

    expect { enqueue(user_id: 1) }.not_to change(SolidQueue::Job, :count)
    expect(SolidQueue::BlockedExecution.count).to eq(0)
  end

  it "lets different users generate at the same time" do
    enqueue(user_id: 1)

    expect { enqueue(user_id: 2) }.to change(SolidQueue::Job, :count).by(1)
  end

  # A permit shorter than the judged generation would let a second billed
  # generation start while the first is still running.
  it "holds the permit for the judged generation budget and recovers an abandoned expired permit" do
    job = described_class.new(user_id: 1)
    expect(described_class.concurrency_duration).to be >= AiService::JUDGED_GENERATION_BUDGET.seconds

    freeze_time do
      permit = SolidQueue::Semaphore.create!(key: job.concurrency_key, value: 0,
                                             expires_at: described_class.concurrency_duration.from_now)
      expect { enqueue(user_id: 1) }.not_to change(SolidQueue::Job, :count)

      travel described_class.concurrency_duration + 1.second
      SolidQueue::Dispatcher::ConcurrencyMaintenance.new(1, 100).send(:expire_semaphores)

      expect(SolidQueue::Semaphore.exists?(permit.id)).to be(false)
      expect { enqueue(user_id: 1) }.to change(SolidQueue::ReadyExecution, :count).by(1)
    end
  end

  it "never limits the hourly batch" do
    enqueue

    expect { enqueue }.to change(SolidQueue::Job, :count).by(1)
    expect(described_class.new.concurrency_limited?).to be(false)
  end
end
