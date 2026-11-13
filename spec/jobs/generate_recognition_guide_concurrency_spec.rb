require "rails_helper"

RSpec.describe GenerateRecognitionGuideJob do
  let(:user) { User.create!(email: "guide-queue@example.com", provider: "fake", api_keys: { "fake" => "fake-test-key" }) }

  def enqueue_guide(**overrides)
    SolidQueue::Job.enqueue(described_class.new(**{ group_key: "code_smell", user_id: user.id }.merge(overrides)))
  end

  it "discards one user's overlapping request for the same group" do
    enqueue_guide

    expect { enqueue_guide }.not_to change(SolidQueue::Job, :count)
    expect(SolidQueue::BlockedExecution.count).to eq(0)
  end

  it "never discards another user's request for the same group, since each writes their own row" do
    other = User.create!(email: "guide-queue-other@example.com", provider: "fake", api_keys: { "fake" => "fake-test-key" })
    enqueue_guide

    expect { enqueue_guide(user_id: other.id) }.to change(SolidQueue::ReadyExecution, :count).by(1)
  end
end
