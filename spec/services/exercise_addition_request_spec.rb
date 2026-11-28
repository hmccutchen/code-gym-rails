require "rails_helper"

RSpec.describe ExerciseAdditionRequest do
  include AuthHelpers
  self.use_transactional_tests = false

  let!(:user) { create_fake_provider_user }
  let!(:exercise) do
    user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
      section_order: %w[code_review], problem_set: { "code_review" => { "question" => "Review this" } })
  end
  let(:uuid) { SecureRandom.uuid }

  before { allow(GenerateAdditionalExerciseJob).to receive(:perform_later).and_return(true) }
  after { user.destroy! if User.exists?(user.id) }

  def request(**changes)
    described_class.call(**{ user: user, exercise: exercise, request_uuid: uuid, kind: "pattern",
      draft_scope: exercise.draft_scope, revision: exercise.active_section_keys.size,
      enqueue: ->(addition) { GenerateAdditionalExerciseJob.perform_later(addition_id: addition.id) } }.merge(changes))
  end

  it "persists one request before enqueue and replays its UUID without changing its kind" do
    expect(GenerateAdditionalExerciseJob).to receive(:perform_later) do |addition_id:|
      expect(ExerciseAddition.find(addition_id).status).to eq("queued")
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      true
    end
    first = request
    replay = request(kind: "challenge")

    expect(first.status).to eq(:accepted)
    expect(replay).to have_attributes(status: :replayed, addition: first.addition)
    expect(first.addition.reload.kind).to eq("pattern")
  end

  it "keeps a failed UUID terminal and requires a fresh UUID to retry" do
    first = request
    first.addition.update!(status: "failed")

    expect(request.status).to eq(:replayed)
    expect(request(request_uuid: SecureRandom.uuid).status).to eq(:accepted)
    expect(GenerateAdditionalExerciseJob).to have_received(:perform_later).twice
  end

  it "rejects a second active operation and outdated manifests without writes" do
    expect(request(revision: 0).status).to eq(:manifest_changed)
    expect(request(draft_scope: "stale").status).to eq(:stale)
    expect(ExerciseAddition.count).to eq(0)
    request
    expect(request(request_uuid: SecureRandom.uuid).status).to eq(:busy)
  end

  it "fails a lost queued operation on mutation before accepting an explicit retry" do
    first = request.addition
    first.update!(created_at: DailyExercise::JOB_PICKUP_MARGIN.ago - 1.second)

    expect(request(request_uuid: SecureRandom.uuid).status).to eq(:accepted)
    expect(first.reload.status).to eq("failed")
  end

  it "records enqueue failure without leaving the submission gate active" do
    allow(GenerateAdditionalExerciseJob).to receive(:perform_later).and_raise(StandardError, "queue unavailable")

    result = request

    expect(result.status).to eq(:failed)
    expect(result.addition.reload.status).to eq("failed")
    expect(exercise.exercise_additions.active).to be_empty
  end

  it "does not fail a request claimed before an ambiguous enqueue error" do
    allow(GenerateAdditionalExerciseJob).to receive(:perform_later) do |addition_id:|
      ExerciseAddition.find(addition_id).update!(status: "running", claimed_at: Time.current)
      raise StandardError, "enqueue acknowledgement lost"
    end

    result = request

    expect(result.addition.reload.status).to eq("running")
  end

  it "refuses submitted, unavailable and foreign requests" do
    expect(request(kind: "code_review").status).to eq(:unavailable)
    user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current)
    expect(request.status).to eq(:submitted)
    other = create_fake_provider_user
    expect(request(user: other).status).to eq(:not_current)
  ensure
    other&.destroy!
  end

  it "checks current identity in the owner zone even when the caller uses UTC" do
    travel_to(Time.utc(2026, 11, 28, 4)) do
      user.update!(time_zone: "Pacific/Honolulu")
      exercise.update!(date: Date.new(2026, 11, 27))

      expect(request.status).to eq(:accepted)
    end
  end

  it "recovers a dead worker only after its deadline" do
    addition = request.addition
    addition.update!(status: "running", claimed_at: Time.current)
    expect(described_class.recover!(exercise)).to eq(:unchanged)
    addition.update!(claimed_at: DailyExercise::REGENERATION_STALE_AFTER.ago - 1.second)

    expect(described_class.recover!(exercise)).to eq(:recovered)
    expect(addition.reload.status).to eq("failed")
  end
end
