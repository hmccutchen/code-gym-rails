require "rails_helper"

RSpec.describe GenerateConceptReferenceJob, type: :job do
  let(:user) { User.create!(email: "job@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }) }

  let(:reference_hash) do
    {
      "tagline"      => "Avoid N+1 by eager loading.",
      "explanation"  => "Explanation here.",
      "code_example" => "User.includes(:posts)",
      "senior_lens"  => "Reach for includes when iterating.",
      "guide_plain_language" => "Plain-language guide.",
      "guide_worked_example" => "A worked example.",
      "guide_pitfalls"       => "What people get wrong.",
      "ladder_junior"             => "j",
      "ladder_mid_level"          => "m",
      "ladder_senior"             => "s",
      "ladder_principal_engineer" => "p"
    }
  end

  def stub_service(returning: reference_hash)
    service = instance_double(ClaudeService)
    allow(service).to receive(:generate_concept_reference)
      .with(user, "n_plus_one", "ruby_rails").and_return(returning)
    allow(AiService).to receive(:for).with(user).and_return(service)
    service
  end

  it "creates a ConceptReference with the generated fields" do
    stub_service
    expect {
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
    }.to change(ConceptReference, :count).by(1)

    ref = ConceptReference.last
    expect(ref.concept).to eq("n_plus_one")
    expect(ref.language).to eq("ruby_rails")
    expect(ref.tagline).to eq("Avoid N+1 by eager loading.")
    expect(ref.generation_version).to eq(1)
  end

  it "is a no-op when the user already sees a reference, here the shared one (does not call the provider)" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "existing")
    expect(AiService).not_to receive(:for)
    expect {
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
    }.not_to change(ConceptReference, :count)
  end

  it "is a no-op when the user no longer exists" do
    expect(AiService).not_to receive(:for)
    expect {
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: -1)
    }.not_to change(ConceptReference, :count)
  end

  it "swallows provider errors without raising and creates no row" do
    service = instance_double(ClaudeService)
    allow(service).to receive(:generate_concept_reference)
      .and_raise(ProviderError::RateLimitError, "slow down")
    allow(AiService).to receive(:for).with(user).and_return(service)

    expect {
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
    }.not_to change(ConceptReference, :count)
  end

  it "notes a setup error as a setup failure, so Learn stops waiting, and creates no row" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(AiService).to receive(:for).with(user).and_raise(SetupError, "User #{user.id} has no recognized AI provider configured")
    allow(Rails.logger).to receive(:error)

    expect {
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
    }.not_to change(ConceptReference, :count)
    expect(ConceptReferenceFailures.read(user_id: user.id, concept: "n_plus_one", language: "ruby_rails")).to include("kind" => "setup")
    expect(Rails.logger).to have_received(:error).with(/user #{user.id}.*no recognized AI provider/)
  end

  it "is a no-op for the 'other' concept (does not call the provider)" do
    expect(AiService).not_to receive(:for)
    expect {
      described_class.perform_now(concept: "other", language: "ruby_rails", user_id: user.id)
    }.not_to change(ConceptReference, :count)
  end

  it "swallows a unique-index race without raising" do
    stub_service
    # Simulate another job winning the race between the existence check and create!
    allow(ConceptReference).to receive(:create!)
      .and_raise(ActiveRecord::RecordNotUnique, "duplicate key")

    expect {
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
    }.not_to raise_error
  end

  # The model validation can lose the race before the unique index does, so RecordInvalid must be swallowed too.
  it "swallows a RecordInvalid from a concurrently-created row without raising" do
    stub_service
    other = ConceptReference.new(concept: "n_plus_one", language: "ruby_rails")
    other.errors.add(:concept, :taken)
    allow(ConceptReference).to receive(:create!)
      .and_raise(ActiveRecord::RecordInvalid.new(other))

    expect {
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
    }.not_to raise_error
  end

  it "re-raises a RecordInvalid unrelated to the concept uniqueness race" do
    stub_service
    other = ConceptReference.new(concept: "n_plus_one", language: nil)
    other.errors.add(:language, :blank)
    allow(ConceptReference).to receive(:create!)
      .and_raise(ActiveRecord::RecordInvalid.new(other))

    expect {
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
    }.to raise_error(ActiveRecord::RecordInvalid)
  end

  describe ".queue_missing" do
    include ActiveJob::TestHelper

    let(:pairs) { [ [ "n_plus_one", "ruby_rails" ], [ "caching", "ruby_rails" ], [ "closures", "javascript" ] ] }

    it "queues a write-up for each pair the user sees no reference for, at the priority given" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails")
      ConceptReference.create!(concept: "caching", language: "ruby_rails", user: User.create!(email: "x@example.com"))

      described_class.queue_missing(user, pairs, priority: JobPriority::BULK)

      queued = enqueued_jobs.select { |job| job["job_class"] == described_class.name }
      expect(queued.map { |job| job["arguments"].first.slice("concept", "language", "user_id") })
        .to contain_exactly({ "concept" => "caching", "language" => "ruby_rails", "user_id" => user.id },
                            { "concept" => "closures", "language" => "javascript", "user_id" => user.id })
      expect(queued.map { |job| job["priority"] }.uniq).to eq([ JobPriority::BULK ])
    end

    it "queues nothing for a trial account" do
      expect { described_class.queue_missing(create_trial_user, pairs) }.not_to have_enqueued_job(described_class)
    end
  end

  describe "ownership" do
    let(:teammate) { User.create!(email: "teammate@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-other" }) }

    it "writes the row as the user's own" do
      stub_service
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)

      expect(ConceptReference.sole.user).to eq(user)
    end

    it "writes a user's own row when only another user's row exists" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "theirs", user: teammate)
      stub_service

      expect {
        described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
      }.to change(ConceptReference, :count).by(1)
      expect(ConceptReference.find_by!(user: teammate).tagline).to eq("theirs")
      expect(ConceptReference.find_by!(user: user).tagline).to eq("Avoid N+1 by eager loading.")
    end

    it "leaves the shared row untouched and writes the user's own row on a refresh, past the shared row's counter" do
      shared = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "shared", generation_version: 3)
      stub_service

      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true)

      expect(shared.reload.tagline).to eq("shared")
      own = ConceptReference.find_by!(user: user)
      expect(own).to be_complete
      expect(own.generation_version).to eq(4)
      expect(ConceptReference.for(user, concept: "n_plus_one", language: "ruby_rails")).to eq(own)
    end

    it "calls no provider for a trial account" do
      trial = create_trial_user
      expect(AiService).not_to receive(:for)

      expect {
        described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: trial.id)
      }.not_to change(ConceptReference, :count)
    end

    it "writes nothing and finishes cleanly when the account is deleted during the provider call" do
      service = instance_double(ClaudeService)
      allow(service).to receive(:generate_concept_reference) do
        AccountDeletion.call(user)
        reference_hash
      end
      allow(AiService).to receive(:for).with(user).and_return(service)

      expect {
        described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
      }.not_to raise_error
      expect(ConceptReference.count).to eq(0)
      expect(User.exists?(user.id)).to be(false)
    end

    it "does not rewrite the user's row when the account is deleted during a refresh" do
      row = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "old", user: user)
      service = instance_double(ClaudeService)
      allow(service).to receive(:generate_concept_reference) do
        ConceptReference.where(id: row.id).delete_all
        User.where(id: user.id).delete_all
        reference_hash
      end
      allow(AiService).to receive(:for).with(user).and_return(service)

      expect {
        described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true)
      }.not_to raise_error
      expect(ConceptReference.count).to eq(0)
    end
  end

  describe "guide persistence" do
    it "persists the guide fields alongside the reference fields" do
      stub_service
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)

      ref = ConceptReference.last
      expect(ref.guide_plain_language).to eq("Plain-language guide.")
      expect(ref.guide_worked_example).to eq("A worked example.")
      expect(ref.guide_pitfalls).to eq("What people get wrong.")
      expect(ref).to be_guide
    end

    it "leaves the guide null when the provider omits it, without failing" do
      stub_service(returning: reference_hash.except(*ConceptReference::GUIDE_FIELDS))
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)

      ref = ConceptReference.last
      expect(ref.tagline).to eq("Avoid N+1 by eager loading.")
      expect(ref).not_to be_guide
    end

    it "writes the ladder with the rest of the row" do
      stub_service
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)

      expect(ConceptReference.last).to be_complete
    end
  end

  describe "refresh" do
    def legacy_row
      ConceptReference.create!(
        concept: "n_plus_one", language: "ruby_rails", user: user,
        tagline: "old tagline", explanation: "old", code_example: "old", senior_lens: "old"
      )
    end

    # ResponsesController enqueues on first exposure and relies on this default being a no-op when any row exists.
    it "does not touch a guide-less row by default" do
      legacy_row
      expect(AiService).not_to receive(:for)

      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)

      expect(ConceptReference.last.tagline).to eq("old tagline")
    end

    it "regenerates a guide-less row when asked to" do
      row = legacy_row
      stub_service

      expect {
        described_class.perform_now(
          concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true
        )
      }.not_to change(ConceptReference, :count)

      row.reload
      expect(row.tagline).to eq("Avoid N+1 by eager loading.")
      expect(row).to be_guide
      expect(row.generation_version).to eq(1)
    end

    it "advances the completion counter on every successful refresh even when nothing else changes" do
      attributes = reference_hash.except(*ConceptReference::LADDER_FIELDS)
      row = ConceptReference.create!(attributes.merge(concept: "n_plus_one", language: "ruby_rails", user: user))
      stub_service(returning: attributes)

      freeze_time do
        2.times do
          expect {
            described_class.perform_now(concept: row.concept, language: row.language, user_id: user.id, refresh: true)
          }.to change { row.reload.generation_version }.by(1)
        end
      end

      expect(row.attributes.slice(*attributes.keys)).to eq(attributes)
    end

    it "advances from the locked counter when another incomplete refresh finishes during the provider call" do
      row = legacy_row
      service = stub_service
      allow(service).to receive(:generate_concept_reference) do
        row.update!(generation_version: 1, ladder_junior: "another attempt")
        reference_hash.except(*ConceptReference::LADDER_FIELDS)
      end

      described_class.perform_now(concept: row.concept, language: row.language, user_id: user.id, refresh: true)

      expect(row.reload.generation_version).to eq(2)
      expect(row).not_to be_ladder
    end

    it "rewrites a guided row that has no ladder when asked to refresh" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "old", user: user,
                               guide_plain_language: "p", guide_worked_example: "w", guide_pitfalls: "x")
      stub_service

      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true)

      expect(ConceptReference.last.tagline).to eq("Avoid N+1 by eager loading.")
      expect(ConceptReference.last).to be_ladder
    end

    it "keeps a valid reference when a ladder refresh returns malformed required prose" do
      row = ConceptReference.create!(
        reference_hash.except(*ConceptReference::LADDER_FIELDS).merge(concept: "n_plus_one", language: "ruby_rails", user: user)
      )
      before = row.attributes
      service = ClaudeService.new(user.api_key)
      allow(AiService).to receive(:for).with(user).and_return(service)
      allow(service).to receive(:call).and_return(
        text: reference_hash.merge("explanation" => false).to_json, input_tokens: 10, output_tokens: 20,
        model: "claude-sonnet-5-5"
      )
      expect(Rails.logger).to receive(:warn).with(/Failed to generate concept reference/)

      described_class.perform_now(concept: row.concept, language: row.language, user_id: user.id, refresh: true)

      expect(row.reload.attributes).to eq(before)
      expect(row).not_to be_complete
    end

    it "leaves a fully written row alone even when asked to refresh" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "kept", user: user,
                               guide_plain_language: "p", guide_worked_example: "w", guide_pitfalls: "x",
                               ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p",
                               lesson: { "definition" => "d" })
      expect(AiService).not_to receive(:for)

      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true)

      expect(ConceptReference.last.tagline).to eq("kept")
      expect(ConceptReference.last.generation_version).to eq(0)
    end

    it "rewrites a row with a guide and ladder but no lesson when asked to refresh, and stores the lesson" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "old", user: user,
                               guide_plain_language: "p", guide_worked_example: "w", guide_pitfalls: "x",
                               ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")
      stub_service(returning: reference_hash.merge("lesson" => { "definition" => "d" }))

      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true)

      expect(ConceptReference.last.tagline).to eq("Avoid N+1 by eager loading.")
      expect(ConceptReference.last.lesson).to eq("definition" => "d")
    end

    it "leaves a row with a guide and ladder but no lesson alone without a refresh" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "kept", user: user,
                               guide_plain_language: "p", guide_worked_example: "w", guide_pitfalls: "x",
                               ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")
      expect(AiService).not_to receive(:for)

      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)

      expect(ConceptReference.last.tagline).to eq("kept")
    end

    # Two jobs can both pass the fully_written? check; the second to write must discard its result.
    it "does not overwrite a row that became fully written between the check and the write" do
      row = legacy_row
      stub_service

      allow_any_instance_of(ConceptReference).to receive(:with_lock) do |record, &block|
        record.update!(
          guide_plain_language: "winner plain", guide_worked_example: "winner worked",
          guide_pitfalls: "winner pitfalls",
          ladder_junior: "winner j", ladder_mid_level: "winner m", ladder_senior: "winner s", ladder_principal_engineer: "winner p",
          lesson: { "definition" => "winner" }, generation_version: 1
        )
        block.call
      end

      described_class.perform_now(
        concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true
      )

      row.reload
      expect(row.guide_plain_language).to eq("winner plain")
      expect(row.tagline).to eq("old tagline")
      expect(row.generation_version).to eq(1)
    end

    it "logs a skip, not a generation, and keeps the failure note when the row became fully written during the call" do
      row = legacy_row
      service = stub_service
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      allow(service).to receive(:generate_concept_reference) do
        ConceptReferenceFailures.record(user_id: user.id, concept: "n_plus_one", language: "ruby_rails",
                                        error: ProviderError::RateLimitError.new("slow down"))
        row.update!(reference_hash.merge("lesson" => { "definition" => "winner" }))
        reference_hash
      end
      allow(Rails.logger).to receive(:info)

      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true)

      expect(Rails.logger).to have_received(:info).with(/Skipped concept reference for n_plus_one\/ruby_rails: already fully written/)
      expect(Rails.logger).not_to have_received(:info).with(/Generated concept reference/)
      expect(ConceptReferenceFailures.read(user_id: user.id, concept: "n_plus_one", language: "ruby_rails")).to be_present
    end
  end
end
