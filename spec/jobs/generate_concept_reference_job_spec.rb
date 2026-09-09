require "rails_helper"

RSpec.describe GenerateConceptReferenceJob do
  let(:user) { User.create!(email: "job@example.com", name: "Job", api_key: "sk-ant-test", provider: "anthropic") }

  let(:reference_hash) do
    {
      "tagline"      => "Avoid N+1 by eager loading.",
      "explanation"  => "Explanation here.",
      "code_example" => "User.includes(:posts)",
      "senior_lens"  => "Reach for includes when iterating.",
      "guide_plain_language" => "Plain-language guide.",
      "guide_worked_example" => "A worked example.",
      "guide_pitfalls"       => "What people get wrong."
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
  end

  it "is a no-op when a reference already exists (does not call the provider)" do
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
      .and_raise(AiService::RateLimitError, "slow down")
    allow(AiService).to receive(:for).with(user).and_return(service)

    expect {
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
    }.not_to change(ConceptReference, :count)
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

  # The model validation's SELECT can see a concurrently-committed row and
  # raise RecordInvalid before the database's own unique index ever gets a
  # chance to raise RecordNotUnique — the same doubled-uniqueness shape
  # User#resume_generation! already handles for its date race. With the bulk
  # backfill enqueuing dozens of jobs at once, this path is the common way a
  # concurrent create loses, not the rare one, so it must be swallowed too.
  it "swallows a RecordInvalid from a concurrently-created row without raising" do
    stub_service
    # Simulates the model validation losing the same race RecordNotUnique
    # covers above: the winner's row already committed, so the uniqueness
    # check on this attempt fails on :concept exactly as it would for real.
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
      stub_service(returning: reference_hash.except(*AiService::CONCEPT_GUIDE_FIELDS))
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)

      ref = ConceptReference.last
      expect(ref.tagline).to eq("Avoid N+1 by eager loading.")
      expect(ref).not_to be_guide
    end
  end

  describe "refresh_guide" do
    def legacy_row
      ConceptReference.create!(
        concept: "n_plus_one", language: "ruby_rails",
        tagline: "old tagline", explanation: "old", code_example: "old", senior_lens: "old"
      )
    end

    # The default keeps every existing caller unchanged: ResponsesController
    # enqueues on first exposure and must stay a no-op when any row exists.
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
          concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh_guide: true
        )
      }.not_to change(ConceptReference, :count)

      row.reload
      expect(row.tagline).to eq("Avoid N+1 by eager loading.")
      expect(row).to be_guide
    end

    it "is still a no-op for a row that already has a guide" do
      legacy_row.update!(
        guide_plain_language: "p", guide_worked_example: "w", guide_pitfalls: "x"
      )
      expect(AiService).not_to receive(:for)

      described_class.perform_now(
        concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh_guide: true
      )
    end

    # Two jobs can both pass the initial existing.guide? check before either
    # writes. The second one to reach the write must discard its result rather
    # than clobber the winner's guide.
    it "does not overwrite a guide that appeared between the check and the write" do
      row = legacy_row
      stub_service

      allow_any_instance_of(ConceptReference).to receive(:with_lock) do |record, &block|
        record.update!(
          guide_plain_language: "winner plain", guide_worked_example: "winner worked",
          guide_pitfalls: "winner pitfalls"
        )
        block.call
      end

      described_class.perform_now(
        concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh_guide: true
      )

      row.reload
      expect(row.guide_plain_language).to eq("winner plain")
      expect(row.tagline).to eq("old tagline")
    end
  end
end
