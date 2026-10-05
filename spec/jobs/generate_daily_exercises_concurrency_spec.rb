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

  it "never limits the hourly batch" do
    enqueue

    expect { enqueue }.to change(SolidQueue::Job, :count).by(1)
    expect(described_class.new.concurrency_limited?).to be(false)
  end
end
