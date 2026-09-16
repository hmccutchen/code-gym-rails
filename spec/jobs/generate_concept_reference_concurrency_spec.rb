require "rails_helper"

RSpec.describe GenerateConceptReferenceJob do
  let(:user) { User.create!(email: "reference-queue@example.com", name: "Queue", api_key: "fake-test-key", provider: "fake") }
  let(:reference) { AiService::CONCEPT_REFERENCE_FIELDS.index_with { "Reference text." } }
  let(:service) { instance_double(FakeService, generate_concept_reference: reference) }
  let(:worker) do
    SolidQueue::Process.create!(kind: "Worker", name: SecureRandom.uuid, pid: Process.pid,
                               hostname: "localhost", last_heartbeat_at: Time.current)
  end

  before { allow(AiService).to receive(:for).and_return(service) }

  def enqueue_reference(**overrides)
    job = described_class.new(**{ concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true }.merge(overrides))
    SolidQueue::Job.enqueue(job)
  end

  def perform_next
    SolidQueue::ReadyExecution.claim([ "default" ], 1, worker.id).sole.perform
  end

  it "discards overlapping queued requests for the shared reference across users and refresh modes" do
    enqueue_reference

    expect {
      enqueue_reference(user_id: user.id + 1, refresh: false)
    }.not_to change(SolidQueue::Job, :count)
    expect(SolidQueue::BlockedExecution.count).to eq(0)
  end

  it "discards requests received during the provider call even when the result is incomplete" do
    allow(service).to receive(:generate_concept_reference) do
      enqueue_reference
      reference
    end
    enqueue_reference

    perform_next

    expect(service).to have_received(:generate_concept_reference).once
    expect(SolidQueue::ReadyExecution.count).to eq(0)
    expect(ConceptReference.find_by!(concept: "n_plus_one", language: "ruby_rails").generation_version).to eq(1)
  end

  it "allows an explicit retry after an incomplete generation finishes" do
    enqueue_reference
    perform_next
    enqueue_reference
    perform_next

    expect(service).to have_received(:generate_concept_reference).twice
    expect(ConceptReference.find_by!(concept: "n_plus_one", language: "ruby_rails").generation_version).to eq(2)
  end

  it "releases the permit after a provider failure" do
    allow(service).to receive(:generate_concept_reference).and_raise(AiService::RateLimitError, "slow down")
    enqueue_reference
    perform_next

    expect { enqueue_reference }.to change(SolidQueue::ReadyExecution, :count).by(1)
    expect(ConceptReference.count).to eq(0)
  end

  it "keeps different concepts and language buckets independent" do
    expect {
      enqueue_reference
      enqueue_reference(concept: "memoization")
      enqueue_reference(language: "javascript")
    }.to change(SolidQueue::ReadyExecution, :count).by(3)
  end

  it "holds the permit for the provider budget and recovers an abandoned expired permit" do
    job = described_class.new(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
    budget = AiService.call_budget_seconds(AiService::CONCEPT_REFERENCE_READ_TIMEOUT)
    expect(described_class.concurrency_duration).to be >= budget.seconds
    expect(job.concurrency_key).to be_present

    freeze_time do
      permit = SolidQueue::Semaphore.create!(key: job.concurrency_key, value: 0,
                                             expires_at: described_class.concurrency_duration.from_now)
      expect { enqueue_reference }.not_to change(SolidQueue::Job, :count)

      travel described_class.concurrency_duration + 1.second
      SolidQueue::Dispatcher::ConcurrencyMaintenance.new(1, 100).send(:expire_semaphores)

      expect(SolidQueue::Semaphore.exists?(permit.id)).to be(false)
      expect { enqueue_reference }.to change(SolidQueue::ReadyExecution, :count).by(1)
    end
  end
end
