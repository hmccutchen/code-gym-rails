require "rails_helper"

RSpec.describe ExerciseAddition, type: :model do
  let(:user) { create_user_with_key }
  let(:exercise) { create_exercise_for(user) }

  def create_exercise_for(owner)
    DailyExercise.create!(user: owner, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "What would you change?" } })
  end

  def attributes_for(set = exercise, **overrides)
    { daily_exercise_id: set.id, request_uuid: SecureRandom.uuid, kind: "pattern", draft_scope: set.draft_scope,
      date: set.date }.merge(overrides)
  end

  it "stores a queued request against its exercise" do
    attributes = attributes_for
    addition = described_class.create!(attributes)

    expect(addition.reload).to have_attributes(**attributes, status: "queued", claimed_at: nil)
    expect(addition.daily_exercise).to eq(exercise)
  end

  it "enforces UUID uniqueness per exercise even after an operation settles" do
    attributes = attributes_for(status: "failed")
    described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) { described_class.insert_all!([ attributes ]) }
    end.to raise_error(ActiveRecord::RecordNotUnique)

    other = create_exercise_for(create_user_with_key(email: "another-addition@example.com"))
    expect(described_class.create!(attributes_for(other, request_uuid: attributes[:request_uuid]))).to be_persisted
  end

  it "prevents a second active request while either a queued or running request exists" do
    addition = described_class.create!(attributes_for)

    expect do
      described_class.transaction(requires_new: true) { described_class.insert_all!([ attributes_for ]) }
    end.to raise_error(ActiveRecord::RecordNotUnique)

    addition.update!(status: "running", claimed_at: Time.current)
    expect do
      described_class.transaction(requires_new: true) { described_class.insert_all!([ attributes_for ]) }
    end.to raise_error(ActiveRecord::RecordNotUnique)

    addition.update!(status: "failed", claimed_at: nil)
    expect(described_class.create!(attributes_for)).to be_persisted
  end

  it "does not accept an unrecognized kind or status" do
    addition = described_class.new(attributes_for(kind: "retired_kind", status: "unknown"))

    expect(addition).not_to be_valid
    expect(addition.errors.attribute_names).to contain_exactly(:kind, :status)
  end

  it "deletes requests with an individually destroyed exercise" do
    addition = described_class.create!(attributes_for)

    exercise.destroy!

    expect(described_class.exists?(addition.id)).to be(false)
  end
end
