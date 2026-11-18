require "rails_helper"

RSpec.describe LearnerExtraction do
  let(:user) { User.create!(email: "ledger@example.com", provider: "fake", api_keys: { "fake" => "fake-key" }) }
  let(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" } },
                          plan_notes: { "size" => 2, "daily_kinds" => %w[code_review design_comparison] })
  end

  def stored = exercise.reload.plan_notes

  it "reads an untouched set as unread, with no attempts" do
    expect(described_class.for(exercise)).to have_attributes(attempts: 0, reply_attempts: 0, closed?: false)
  end

  it "counts an attempt on the set as text-free counts, leaving the plan's own notes alone" do
    expect(described_class.count_attempt!(exercise, close: false)).to be(true)

    expect(stored).to eq("size" => 2, "daily_kinds" => %w[code_review design_comparison],
                         "learner_extraction" => { "attempts" => 1, "reply_attempts" => 0 })
  end

  it "closes the set with the attempt when asked, and counts no attempt on a closed set" do
    described_class.count_attempt!(exercise, close: true)

    expect(described_class.for(exercise.reload)).to have_attributes(attempts: 1, closed?: true)
    expect(described_class.count_attempt!(exercise, close: false)).to be(false)
    expect(described_class.for(exercise.reload).attempts).to eq(1)
  end

  it "counts at most two attempts" do
    2.times { described_class.count_attempt!(exercise, close: false) }

    expect(described_class.count_attempt!(exercise, close: false)).to be(false)
    expect(described_class.for(exercise.reload).attempts).to eq(described_class::MAX_ATTEMPTS)
  end

  it "closes a set once, keeping the first time" do
    described_class.close!(exercise)
    first = described_class.for(exercise.reload).closed_at

    travel 1.minute do
      described_class.close!(exercise)
    end

    expect(described_class.for(exercise.reload).closed_at).to eq(first)
  end

  it "reads and writes under the exercise row lock, after the user's" do
    locks = []
    allow(User).to receive(:lock).and_wrap_original { |original, *args| locks << [ :user, *args ] && original.call(*args) }
    allow(exercise).to receive(:lock!).and_wrap_original { |original, *args| (locks << :exercise) && original.call(*args) }

    described_class.close!(exercise)

    expect(locks).to eq([ [ :user, "FOR SHARE" ], :exercise ])
  end

  it "answers :gone for a set deleted before the write" do
    stale = DailyExercise.find(exercise.id)
    exercise.destroy!

    expect(described_class.close!(stale)).to eq(:gone)
    expect(described_class.count_attempt!(stale, close: true)).to eq(:gone)
  end

  it "counts reply attempts apart from extraction attempts, at most two, when the block takes the claim" do
    token = Time.current.floor(6)

    take = ->(spent) { spent ? :exhausted : token }

    expect(described_class.count_reply_attempt!(exercise, &take)).to eq(token)
    expect(described_class.count_reply_attempt!(exercise, &take)).to eq(token)
    expect(described_class.count_reply_attempt!(exercise, &take)).to eq(:exhausted)

    expect(described_class.for(exercise.reload)).to have_attributes(reply_attempts: 2, attempts: 0)
  end

  it "counts no reply attempt when the block refuses with a symbol" do
    expect(described_class.count_reply_attempt!(exercise) { :busy }).to eq(:busy)

    expect(described_class.for(exercise.reload).reply_attempts).to eq(0)
  end

  it "is dropped by .clear!, leaving the rest of the plan's notes" do
    described_class.count_attempt!(exercise, close: true)

    described_class.clear!(exercise)

    expect(stored).to eq("size" => 2, "daily_kinds" => %w[code_review design_comparison])
    expect(exercise.plan_notes).not_to have_key("learner_extraction")
  end

  describe ".forget_all!" do
    it "stamps a forgotten time on each of the owner's existing ledgers, keeping their counts and the plan's notes" do
      described_class.count_attempt!(exercise, close: false)
      untouched = DailyExercise.create!(user: user, date: Date.current - 1, generated_at: Time.current, language: "ruby_rails",
                                        problem_set: exercise.problem_set, plan_notes: { "size" => 2 })

      described_class.forget_all!(user)

      expect(described_class.for(exercise.reload)).to have_attributes(attempts: 1, forgotten_at: Time.current.iso8601)
      expect(stored).to include("size" => 2, "daily_kinds" => %w[code_review design_comparison])
      expect(untouched.reload.plan_notes).to eq("size" => 2)
    end

    it "leaves another account's ledgers alone" do
      other = User.create!(email: "other-ledger@example.com", provider: "fake", api_keys: { "fake" => "fake-key" })
      theirs = DailyExercise.create!(user: other, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                                     problem_set: exercise.problem_set)
      described_class.count_attempt!(theirs, close: false)

      described_class.forget_all!(user)

      expect(described_class.for(theirs.reload).forgotten_at).to be_nil
    end
  end
end
