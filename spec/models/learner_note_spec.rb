require "rails_helper"

RSpec.describe LearnerNote do
  include AuthHelpers

  let(:user) { create_user_with_key }
  let(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" } })
  end

  def note(**attrs) = described_class.new(user: user, daily_exercise: exercise, **attrs)
  def refused(record) = record.tap(&:validate).errors.attribute_names

  it "keeps the account's setting apart from its notes" do
    note.save!

    expect(user.reload.learner_notes_enabled).to be(false)
    expect(user.learner_notes).to contain_exactly(an_instance_of(described_class))
  end

  it "belongs to the owner of its set, so deleting that owner can never be blocked" do
    other = create_user_with_key(email: "other-#{SecureRandom.hex(4)}@example.com")

    expect(refused(described_class.new(user: other, daily_exercise: exercise))).to include(:user)
  end

  it "goes with its owner when an account is anonymized" do
    note.save!

    expect { user.anonymize! }.to change { described_class.where(user: user).count }.from(1).to(0)
  end

  it "keeps one row per exercise" do
    note.save!

    expect { described_class.new(user: user, daily_exercise: exercise).save!(validate: false) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "holds a note and an explanation of at most 1,000 characters each" do
    expect(note(body: "a" * 1_000, explanation: "b" * 1_000)).to be_valid
    expect(refused(note(body: "a" * 1_001))).to include(:body)
    expect(refused(note(explanation: "b" * 1_001))).to include(:explanation)
  end

  it "never counts more than two extraction attempts" do
    expect(note(extract_attempts: 2)).to be_valid
    expect(refused(note(extract_attempts: 3))).to include(:extract_attempts)
    expect(refused(note(extract_attempts: -1))).to include(:extract_attempts)
  end

  it "refuses a third attempt in the database too" do
    row = note.tap(&:save!)

    expect { row.update_columns(extract_attempts: 3) }.to raise_error(ActiveRecord::StatementInvalid, /extract_attempts_range/)
  end

  it "never counts more than two reply attempts" do
    expect(note(reply_attempts: 2)).to be_valid
    expect(refused(note(reply_attempts: 3))).to include(:reply_attempts)
    expect(refused(note(reply_attempts: -1))).to include(:reply_attempts)
  end

  it "refuses a third reply attempt in the database too" do
    row = note.tap(&:save!)

    expect { row.update_columns(reply_attempts: 3) }.to raise_error(ActiveRecord::StatementInvalid, /reply_attempts_range/)
  end

  it "hides the note, the explanation and its reply from inspect" do
    shown = note(body: "my private note", explanation: "my own words",
                 explanation_reply: { "sound" => "a sound point", "correction" => nil }).inspect

    expect(shown).not_to include("my private note", "my own words", "a sound point")
    expect(shown).to include("body: [FILTERED]", "explanation: [FILTERED]", "explanation_reply: [FILTERED]")
  end
end
