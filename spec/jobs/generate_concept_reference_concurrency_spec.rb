require "rails_helper"

RSpec.describe GenerateConceptReferenceJob do
  let(:user) { User.create!(email: "reference-queue@example.com", provider: "fake", api_keys: { "fake" => "fake-test-key" }) }
  let(:reference) { ConceptReference::REFERENCE_FIELDS.index_with { "Reference text." } }
  let(:service) { instance_double(FakeService, generate_concept_reference: reference) }
  let(:worker) do
    SolidQueue::Process.create!(kind: "Worker", name: SecureRandom.uuid, pid: Process.pid,
                               hostname: "localhost", last_heartbeat_at: Time.current)
  end

  before { allow(AiService).to receive(:for).and_return(service) }

  def enqueue_reference(priority: nil, **overrides)
    job = described_class.new(**{ concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true }.merge(overrides))
    job.priority = priority
    SolidQueue::Job.enqueue(job)
  end

  def enqueue_bulk_press = enqueue_reference(priority: JobPriority::BACKGROUND, refresh: false)

  def claim_next = SolidQueue::ReadyExecution.claim([ described_class.queue_name ], 1, worker.id).sole

  def perform_next = claim_next.perform

  def holding_claim_elsewhere(key)
    other = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(ActiveRecord::Base.connection_pool.db_config.configuration_hash)
    other.select_value(AdvisoryLock.statement("pg_advisory_lock", key))
    yield
  ensure
    other&.disconnect!
  end

  def claim_free_elsewhere?(key)
    other = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(ActiveRecord::Base.connection_pool.db_config.configuration_hash)
    other.select_value(AdvisoryLock.statement("pg_try_advisory_lock", key))
  ensure
    other&.disconnect!
  end

  def write_row_behind_the_query_cache
    ActiveRecord::Base.connection.raw_connection.exec(ConceptReference.sanitize_sql_array([ <<~SQL, user.id ]))
      INSERT INTO concept_references (user_id, concept, language, created_at, updated_at) VALUES (?, 'n_plus_one', 'ruby_rails', NOW(), NOW())
    SQL
  end

  describe "a click for a concept a bulk press already queued (#777)" do
    it "queues the click beside the press, claims it first at click priority, and calls the provider once" do
      enqueue_bulk_press

      expect { enqueue_reference }.to change(SolidQueue::ReadyExecution, :count).by(1)

      first = claim_next
      expect(first.job.priority).to eq(JobPriority::CLICK)
      first.perform
      perform_next

      expect(service).to have_received(:generate_concept_reference).once
      expect(ConceptReference.where(user: user, concept: "n_plus_one", language: "ruby_rails").count).to eq(1)
      expect(SolidQueue::ReadyExecution.count).to eq(0)
    end

    it "makes no provider call while a running press holds the concept's claim, and writes nothing" do
      enqueue_reference
      allow(Rails.logger).to receive(:info)

      holding_claim_elsewhere(described_class.claim_key(user_id: user.id, language: "ruby_rails", concept: "n_plus_one")) do
        perform_next
      end

      expect(service).not_to have_received(:generate_concept_reference)
      expect(ConceptReference.count).to eq(0)
      expect(Rails.logger).to have_received(:info).with(/Skipped concept reference for n_plus_one\/ruby_rails: another job is writing it/)
    end

    it "keeps another concept's claim apart, so a press on one concept never holds back another" do
      holding_claim_elsewhere(described_class.claim_key(user_id: user.id, language: "ruby_rails", concept: "memoization")) do
        described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
      end

      expect(service).to have_received(:generate_concept_reference).once
    end

    it "releases the claim when the job ends, even after a provider failure" do
      allow(service).to receive(:generate_concept_reference).and_raise(ProviderError::RateLimitError, "slow down")

      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)

      expect(claim_free_elsewhere?(described_class.claim_key(user_id: user.id, language: "ruby_rails", concept: "n_plus_one"))).to be(true)
    end

    it "reads the row again under the claim past the query cache, so a row another job wrote meanwhile calls nothing" do
      enqueue_reference(refresh: false)
      allow(AdvisoryLock).to receive(:hold).and_wrap_original do |hold, key, &block|
        write_row_behind_the_query_cache
        hold.call(key, &block)
      end

      perform_next

      expect(service).not_to have_received(:generate_concept_reference)
    end
  end

  it "discards one user's overlapping queued requests at one priority, across refresh modes" do
    enqueue_reference

    expect {
      enqueue_reference(refresh: false)
    }.not_to change(SolidQueue::Job, :count)
    expect(SolidQueue::BlockedExecution.count).to eq(0)
  end

  it "never discards another user's request for the same concept, since each writes their own row" do
    other = User.create!(email: "reference-queue-other@example.com", provider: "fake", api_keys: { "fake" => "fake-test-key" })
    enqueue_reference

    expect {
      enqueue_reference(user_id: other.id, refresh: false)
    }.to change(SolidQueue::ReadyExecution, :count).by(1)
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
    expect(ConceptReference.find_by!(user: user, concept: "n_plus_one", language: "ruby_rails").generation_version).to eq(1)
  end

  it "allows an explicit retry after an incomplete generation finishes" do
    enqueue_reference
    perform_next
    enqueue_reference
    perform_next

    expect(service).to have_received(:generate_concept_reference).twice
    expect(ConceptReference.find_by!(user: user, concept: "n_plus_one", language: "ruby_rails").generation_version).to eq(2)
  end

  it "releases the permit after a provider failure" do
    allow(service).to receive(:generate_concept_reference).and_raise(ProviderError::RateLimitError, "slow down")
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
    budget = CallProfiles.call_budget_seconds(CallProfiles::CONCEPT_REFERENCE_READ_TIMEOUT)
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
