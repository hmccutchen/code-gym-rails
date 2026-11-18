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

  it "is deleted with its set, as the set's duck thread is" do
    note.save!

    expect(exercise.learner_note).to eq(described_class.last)
    expect { exercise.destroy! }.to change(described_class, :count).from(1).to(0)
  end

  describe ".explain_history" do
    def explained_on(date, concept)
      set = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                                  problem_set: { "code_review" => { "question" => "q", "snippet" => "x" } })
      described_class.create!(user: user, daily_exercise: set, explain_concept: concept, explanation: "words")
    end

    it "counts each concept's earlier explanations and names those on sets dated in the 7 days before" do
      today = Date.current + 30
      explained_on(today - 7, "n_plus_one")
      explained_on(today - 8, "callbacks")
      explained_on(today - 20, "n_plus_one")
      explained_on(today, "service_objects")
      described_class.create!(user: user, daily_exercise: exercise, body: "a note, no explanation")

      history = user.learner_notes.explain_history(before: today)

      expect(history.recent).to eq([ "n_plus_one" ])
      expect(history.counts).to eq("n_plus_one" => 2, "callbacks" => 1)
    end
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

  it "leaves the old extraction and reply counts unused, since the set's ledger holds them now" do
    expect(described_class.column_names).not_to include("extract_attempts", "extracted_at", "reply_attempts")
  end

  it "hides the note, the explanation and its reply from inspect" do
    shown = note(body: "my private note", explanation: "my own words",
                 explanation_reply: { "sound" => "a sound point", "correction" => nil }).inspect

    expect(shown).not_to include("my private note", "my own words", "a sound point")
    expect(shown).to include("body: [FILTERED]", "explanation: [FILTERED]", "explanation_reply: [FILTERED]")
  end
end
