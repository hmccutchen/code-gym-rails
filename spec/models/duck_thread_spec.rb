require "rails_helper"

RSpec.describe DuckThread do
  include AuthHelpers

  let(:user) { create_user_with_key }
  let(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" } })
  end

  def clear(section = "code_review", scope: exercise.reload.draft_scope)
    described_class.clear!(exercise.reload, section, expected_scope: scope)
  end

  def append(message = "stuck", answer: "What runs first?", version: 0)
    described_class.append!(exercise, "code_review", message: message, answer: answer,
                            expected_version: version, expected_scope: exercise.draft_scope)
  end

  describe ".for" do
    it "reads as an empty thread at version 0 before anything is stored, without writing a row" do
      thread = described_class.for(exercise)

      expect(thread.turns_for("code_review")).to eq([])
      expect(thread.version_for("code_review")).to eq(0)
      expect(described_class.count).to eq(0)
    end
  end

  describe ".append!" do
    it "stores the exchange and returns the next version" do
      expect(append).to eq(1)

      thread = described_class.for(exercise.reload)
      expect(thread.turns_for("code_review")).to eq([ { role: "user", content: "stuck" },
                                                      { role: "assistant", content: "What runs first?" } ])
      expect(thread.user_turn_count("code_review")).to eq(1)
      expect(thread.user).to eq(user)
    end

    it "refuses an exchange read at a version that has since moved, and stores nothing" do
      append

      expect(append("second", version: 0)).to eq(:stale)
      expect(described_class.for(exercise.reload).user_turn_count("code_review")).to eq(1)
    end

    it "refuses an exchange once the day is submitted" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)

      expect(append).to eq(:submitted)
      expect(described_class.for(exercise.reload).turns_for("code_review")).to eq([])
    end

    it "keeps each section's thread apart" do
      append
      described_class.append!(exercise, "pattern", message: "other", answer: "reply",
                              expected_version: 0, expected_scope: exercise.draft_scope)

      thread = described_class.for(exercise.reload)
      expect(thread.user_turn_count("code_review")).to eq(1)
      expect(thread.user_turn_count("pattern")).to eq(1)
    end

    it "refuses a reply written for a set that was regenerated while it was on its way" do
      scope = exercise.draft_scope
      exercise.update!(generated_at: 1.minute.from_now)

      expect(described_class.append!(exercise, "code_review", message: "old set", answer: "reply",
                                     expected_version: 0, expected_scope: scope)).to eq(:stale)
      expect(described_class.count).to eq(0)
    end

    it "starts over when the day was regenerated, so the old problems' thread never comes back" do
      append
      exercise.update!(generated_at: 1.minute.from_now)

      expect(described_class.for(exercise.reload).turns_for("code_review")).to eq([])
      expect(append("fresh", version: 0)).to eq(1)
      expect(described_class.for(exercise.reload).turns_for("code_review").first[:content]).to eq("fresh")
    end
  end

  describe ".clear!" do
    it "empties the section, moves the version and counts the clear" do
      append

      expect(clear).to eq(2)

      thread = described_class.for(exercise.reload)
      expect(thread.turns_for("code_review")).to eq([])
      expect(thread.cleared_count("code_review")).to eq(1)
    end

    it "still moves the version on an empty section, so a reply already on its way is refused, but counts no clear" do
      append
      clear

      expect(clear).to eq(3)
      expect(described_class.for(exercise.reload).cleared_count("code_review")).to eq(1)
      expect(append("on its way", version: 2)).to eq(:stale)
    end

    it "refuses a Clear that reaches the lock after the day was submitted, and keeps the thread" do
      append
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)

      expect(clear).to eq(:submitted)
      expect(described_class.for(exercise.reload).user_turn_count("code_review")).to eq(1)
    end

    it "refuses a Clear from a page whose set was regenerated after it was checked, and keeps the new set's thread" do
      old_scope = exercise.draft_scope
      exercise.update!(generated_at: 1.minute.from_now)
      append("on the new set")

      expect(clear(scope: old_scope)).to eq(:stale)
      expect(described_class.for(exercise.reload).user_turn_count("code_review")).to eq(1)
    end

    it "refuses a Clear for an account deleted while it waited" do
      append
      user.anonymize!

      expect(clear).to eq(:deleted)
    end

    it "moves the version even before anything was stored, so a first reply on its way is refused" do
      expect(clear).to eq(1)

      expect(append("first, on its way", version: 0)).to eq(:stale)
      expect(described_class.for(exercise.reload).cleared_count("code_review")).to eq(0)
    end
  end

  describe ".start_over!" do
    it "empties every section and moves its version, so an old tab can't line up with a new thread" do
      append
      described_class.append!(exercise, "pattern", message: "other", answer: "reply",
                              expected_version: 0, expected_scope: exercise.draft_scope)

      described_class.start_over!(exercise.reload)

      thread = described_class.for(exercise.reload)
      expect(thread.turns_for("code_review")).to eq([])
      expect(thread.version_for("code_review")).to eq(2)
      expect(thread.version_for("pattern")).to eq(2)
      expect(append("from the old tab", version: 1)).to eq(:stale)
    end

    it "writes nothing for a day that never stored a thread" do
      described_class.start_over!(exercise)

      expect(described_class.count).to eq(0)
    end
  end

  describe ".expired" do
    it "selects only threads whose exercise is older than KEPT_FOR" do
      append
      old = DailyExercise.create!(user: user, date: Date.current - described_class::KEPT_FOR - 1.day,
                                  generated_at: Time.current, language: "ruby_rails", problem_set: exercise.problem_set)
      described_class.append!(old, "code_review", message: "old", answer: "reply",
                              expected_version: 0, expected_scope: old.draft_scope)
      boundary = DailyExercise.create!(user: user, date: Date.current - described_class::KEPT_FOR,
                                       generated_at: Time.current, language: "ruby_rails", problem_set: exercise.problem_set)
      described_class.append!(boundary, "code_review", message: "kept", answer: "reply",
                              expected_version: 0, expected_scope: boundary.draft_scope)

      expect(described_class.expired.map(&:daily_exercise)).to eq([ old ])
    end
  end

  it "keeps what engineers typed out of inspect" do
    append

    expect(described_class.first.inspect).to include("threads: [FILTERED]")
    expect(described_class.first.inspect).not_to include("stuck")
  end

  it "is deleted when its owner deletes their account" do
    append

    expect { user.anonymize! }.to change(described_class, :count).from(1).to(0)
  end
end
