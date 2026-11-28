require "rails_helper"

RSpec.describe GenerateAdditionalExerciseJob do
  include AuthHelpers
  let(:user) { create_fake_provider_user }
  let(:exercise) do
    user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
      section_order: %w[code_review], problem_set: { "code_review" => { "question" => "Review this" } })
  end
  let(:addition) do
    exercise.exercise_additions.create!(request_uuid: SecureRandom.uuid, kind: "pattern", draft_scope: exercise.draft_scope, date: exercise.date)
  end
  let(:provider) { instance_double(FakeService) }
  let(:context) { { requested_kind: "pattern" }.freeze }

  before do
    allow(AiService).to receive(:for).and_return(provider)
    allow(PracticeGeneration).to receive(:capture_addition).and_return(context)
    allow(provider).to receive(:generate_judged_exercise).and_return(:judged)
    allow(PracticeGeneration).to receive(:commit_append) do |_owner, **options|
      target = options.fetch(:addition)
      expect(target.reload.claimed_at).to eq(options.fetch(:claim))
      target.update!(status: "succeeded", claimed_at: nil)
      PracticeGeneration::Outcome.new(status: :saved, exercise: exercise)
    end
  end

  it "appends one judged fake-provider section through the real capture and commit" do
    allow(AiService).to receive(:for).and_call_original
    allow(PracticeGeneration).to receive(:capture_addition).and_call_original
    allow(PracticeGeneration).to receive(:commit_append).and_call_original
    scope = exercise.draft_scope
    generated_at = exercise.generated_at

    described_class.perform_now(addition_id: addition.id)

    expect(addition.reload.status).to eq("succeeded")
    expect(exercise.reload.active_section_keys).to eq(%w[code_review pattern])
    expect(exercise.draft_scope).to eq(scope)
    expect(exercise.generated_at).to eq(generated_at)
  end

  it "claims and executes one attempt, then ignores duplicate delivery" do
    described_class.perform_now(addition_id: addition.id)
    described_class.perform_now(addition_id: addition.id)

    expect(addition.reload.status).to eq("succeeded")
    expect(provider).to have_received(:generate_judged_exercise).once
  end

  it "never restarts a running attempt even when its lease has expired" do
    addition.update!(status: "running", claimed_at: DailyExercise::REGENERATION_STALE_AFTER.ago - 1.second)

    described_class.perform_now(addition_id: addition.id)

    expect(addition.reload.status).to eq("failed")
    expect(provider).not_to have_received(:generate_judged_exercise)
  end

  it "refuses a queued operation that missed its pickup window" do
    addition.update!(created_at: DailyExercise::JOB_PICKUP_MARGIN.ago - 1.second)

    described_class.perform_now(addition_id: addition.id)

    expect(addition.reload.status).to eq("failed")
    expect(provider).not_to have_received(:generate_judged_exercise)
  end

  it "settles changed inputs without starting a provider call" do
    allow(PracticeGeneration).to receive(:capture_addition).and_return(nil)

    described_class.perform_now(addition_id: addition.id)

    expect(addition.reload.status).to eq("failed")
    expect(provider).not_to have_received(:generate_judged_exercise)
  end

  it "releases the active gate on provider failure without retrying the operation" do
    allow(provider).to receive(:generate_judged_exercise).and_raise(ProviderError, "unavailable")

    described_class.perform_now(addition_id: addition.id)
    described_class.perform_now(addition_id: addition.id)

    expect(addition.reload.status).to eq("failed")
    expect(provider).to have_received(:generate_judged_exercise).once
  end

  { ProviderError::AuthenticationError => "bad_key", ProviderError::BillingError => "out_of_credit" }.each do |error_class, failure|
    it "records #{failure} for the current key without advancing the scheduled-generation hold" do
      user.update!(generation_account_failures: 1)
      allow(provider).to receive(:generate_judged_exercise).and_raise(error_class, "provider refused")

      described_class.perform_now(addition_id: addition.id)

      expect(addition.reload.status).to eq("failed")
      expect(user.reload).to have_attributes(last_generation_failure: failure, generation_account_failures: 1)
    end
  end

  it "does not replace a newer key's failure when the previous key fails late" do
    allow(provider).to receive(:generate_judged_exercise) do
      user.update!(api_keys: { "fake" => "replacement-key" }, last_generation_failure: "outage")
      raise ProviderError::AuthenticationError, "old key refused"
    end

    described_class.perform_now(addition_id: addition.id)

    expect(addition.reload.status).to eq("failed")
    expect(user.reload.last_generation_failure).to eq("outage")
  end

  it "leaves account failure state alone when the added section fails its quality check" do
    user.update!(last_generation_failure: "outage", generation_account_failures: 1)
    allow(provider).to receive(:generate_judged_exercise).and_raise(ProviderError::AllSectionsRejectedError)

    described_class.perform_now(addition_id: addition.id)

    expect(addition.reload.status).to eq("failed")
    expect(user.reload).to have_attributes(last_generation_failure: "outage", generation_account_failures: 1)
  end

  it "does not overwrite a later claim when a failed call returns" do
    replacement = (Time.current + 1.second).floor(6)
    allow(provider).to receive(:generate_judged_exercise) do
      addition.update!(claimed_at: replacement)
      raise ProviderError, "late failure"
    end

    described_class.perform_now(addition_id: addition.id)

    expect(addition.reload).to have_attributes(status: "running", claimed_at: replacement)
    expect(user.reload.last_generation_failure).to be_nil
  end

  it "stops safely after deletion while the provider call is in flight" do
    allow(provider).to receive(:generate_judged_exercise) do
      AccountDeletion.call(user)
      raise ProviderError, "late response"
    end

    expect { described_class.perform_now(addition_id: addition.id) }.not_to raise_error
    expect(ExerciseAddition.exists?(addition.id)).to be(false)
  end
end
