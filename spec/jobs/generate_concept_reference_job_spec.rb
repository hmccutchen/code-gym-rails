require "rails_helper"

RSpec.describe GenerateConceptReferenceJob do
  let(:user) { User.create!(email: "job@example.com", name: "Job", api_key: "sk-ant-test", provider: "anthropic") }

  let(:reference_hash) do
    {
      "tagline"      => "Avoid N+1 by eager loading.",
      "explanation"  => "Explanation here.",
      "code_example" => "User.includes(:posts)",
      "senior_lens"  => "Reach for includes when iterating."
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

  it "swallows a unique-index race without raising" do
    stub_service
    # Simulate another job winning the race between the existence check and create!
    allow(ConceptReference).to receive(:create!)
      .and_raise(ActiveRecord::RecordNotUnique, "duplicate key")

    expect {
      described_class.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
    }.not_to raise_error
  end
end
