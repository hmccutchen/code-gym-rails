require "rails_helper"

RSpec.describe ExtractLearnerItemsJob, "when the set's evidence is deleted during the call" do
  let(:user) do
    User.create!(email: "deleted-mid-call@example.com", time_zone: "UTC", provider: "fake", api_keys: { "fake" => "fake-key" },
                 learner_notes_enabled: true)
  end
  let(:during) { ->(_exercise) { } }

  before { stub_env("LEARNER_NOTES" => "1") }
  around { |example| travel_to(Time.utc(2026, 11, 16, 15)) { example.run } }

  def submitted_set
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "Service Objects", "question" => "When?", "concept" => "service_objects" }
      }
    )
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "It queries per row.", "pattern" => "" },
                          submitted_at: Time.current, ai_review: { "code_review" => { "rating" => "solid" } })
    LearnerNote.create!(user: user, daily_exercise: exercise, body: "I got stuck on includes vs preload.",
                        explain_section: "code_review", explain_concept: "n_plus_one",
                        explain_phrasing: "explain.first", explanation: "It runs one query per row.")
    exercise
  end

  def start_over_unreviewed(exercise)
    response = exercise.daily_response
    response.update_columns(ai_review: nil)
    expect(exercise.start_over!(response_id: response.id)).to eq(:cleared)
  end

  def item(source)
    ref = { "date" => Date.current.iso8601, "source" => source }
    ref["section"] = "code_review" if %w[explanation duck].include?(source)
    LearnerItemsReply::Item.new(concept: "n_plus_one", bucket: "ruby_rails", kind: "concept", term: nil,
                                label: "Practise preloading.", evidence: [ ref ])
  end

  def run_with(exercise, source)
    allow_any_instance_of(FakeService).to receive(:extract_learner_items) do
      during.call(exercise)
      LearnerItemsReply::Result.new(items: [ item(source) ], dropped: {})
    end
    ExtractLearnerItemsJob.perform_now(user_id: user.id, daily_exercise_id: exercise.id,
                                       daily_response_id: exercise.daily_response.id, run: "fallback")
  end

  def citing(source) = LearnerItem.where(user_id: user.id).select { |row| row.evidence.any? { |ref| ref["source"] == source } }

  context "with the note deleted" do
    let(:during) { ->(_exercise) { LearnerNote.remove!(user, LearnerNote.sole.id, :note) } }

    it "writes no item citing the removed note" do
      run_with(submitted_set, "note")
      expect(LearnerNote.sole.body).to be_nil
      expect(citing("note")).to be_empty
    end

    it "still writes an item citing only the duck" do
      run_with(submitted_set, "duck")

      expect(citing("duck").size).to eq(1)
      expect(LearnerExtraction.for(user.daily_exercises.sole)).to have_attributes(attempts: 1, closed?: true)
    end
  end

  context "with the explanation deleted" do
    let(:during) { ->(_exercise) { LearnerNote.remove!(user, LearnerNote.sole.id, :explanation) } }

    it "writes no item citing the removed explanation" do
      run_with(submitted_set, "explanation")
      expect(citing("explanation")).to be_empty
    end
  end

  context "with Delete all" do
    let(:during) { ->(_exercise) { LearnerNote.remove_all!(user) } }

    it "leaves no item behind" do
      run_with(submitted_set, "note")
      expect(LearnerItem.where(user_id: user.id)).to be_empty
    end

    it "leaves no item behind when the item cites only the duck" do
      run_with(submitted_set, "duck")
      expect(LearnerItem.where(user_id: user.id)).to be_empty
    end
  end

  context "with Delete all pressed before the call read the set" do
    it "still writes the call's items" do
      exercise = submitted_set
      LearnerExtraction.count_reply_attempt!(exercise) { Time.current }
      LearnerNote.remove_all!(user)
      LearnerNote.create!(user: user, daily_exercise: exercise, body: "Written again after Delete all.")

      run_with(exercise.reload, "duck")

      expect(LearnerItem.where(user_id: user.id).size).to eq(1)
    end
  end

  context "with Start over" do
    let(:during) { ->(exercise) { start_over_unreviewed(exercise.reload) } }

    it "writes no item from the replaced set, logs it by count, and does not raise" do
      exercise = submitted_set
      log = StringIO.new
      allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(log))

      expect { run_with(exercise, "duck") }.not_to raise_error

      expect(LearnerNote.where(daily_exercise_id: exercise.id)).to be_empty
      expect(LearnerItem.where(user_id: user.id)).to be_empty
      expect(log.string).to include("[learner_items] user #{user.id} run=fallback set_replaced")
    end

    it "leaves the fresh ledger of the replacement response open" do
      exercise = submitted_set
      run_with(exercise, "duck")
      expect(LearnerExtraction.for(exercise.reload)).not_to be_closed
    end
  end

  context "with the note row deleted outright" do
    let(:during) { ->(exercise) { LearnerNote.where(daily_exercise_id: exercise.id).delete_all } }

    it "finishes without raising" do
      expect { run_with(submitted_set, "duck") }.not_to raise_error
    end
  end
end

RSpec.describe ExtractLearnerItemsJob, "when the account is deleted during the call" do
  let(:user) do
    User.create!(email: "account-gone-mid-call@example.com", time_zone: "UTC", provider: "fake", api_keys: { "fake" => "fake-key" },
                 learner_notes_enabled: true)
  end

  before { stub_env("LEARNER_NOTES" => "1") }

  it "finishes without raising" do
    exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                                     problem_set: { "code_review" => { "question" => "Q", "snippet" => "def a; end", "concept" => "n_plus_one" } })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: { "code_review" => "A" },
                          submitted_at: Time.current, ai_review: { "code_review" => { "rating" => "solid" } })
    LearnerNote.create!(user: user, daily_exercise: exercise, body: "stuck")
    allow_any_instance_of(FakeService).to receive(:extract_learner_items) do
      AccountDeletion.call(user)
      LearnerItemsReply::Result.new(items: [], dropped: {})
    end
    log = StringIO.new
    allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(log))

    expect do
      ExtractLearnerItemsJob.perform_now(user_id: user.id, daily_exercise_id: exercise.id,
                                         daily_response_id: exercise.daily_response.id, run: "fallback")
    end.not_to raise_error
    expect(log.string).to include("[learner_items] user #{user.id} run=fallback account_deleted")
  end
end

RSpec.describe ExtractLearnerItemsJob, "when the set moves on before the run writes its ledger" do
  let(:user) do
    User.create!(email: "ledger-race@example.com", time_zone: "UTC", provider: "fake", api_keys: { "fake" => "fake-key" },
                 learner_notes_enabled: true)
  end

  before do
    stub_env("LEARNER_NOTES" => "1")
    allow_any_instance_of(FakeService).to receive(:extract_learner_items)
      .and_return(LearnerItemsReply::Result.new(items: [ duck_item ], dropped: {}))
  end

  around { |example| travel_to(Time.utc(2026, 11, 16, 15)) { example.run } }

  def submitted_set
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => "n_plus_one" } }
    )
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: { "code_review" => "It queries per row." },
                          submitted_at: Time.current, ai_review: { "code_review" => { "rating" => "solid" } })
    LearnerNote.create!(user: user, daily_exercise: exercise, body: "I got stuck on includes vs preload.")
    exercise
  end

  def start_over_unreviewed(exercise)
    response = exercise.daily_response
    response.update_columns(ai_review: nil)
    expect(exercise.start_over!(response_id: response.id)).to eq(:cleared)
  end

  def duck_item
    LearnerItemsReply::Item.new(concept: "n_plus_one", bucket: "ruby_rails", kind: "concept", term: nil, label: "Practise preloading.",
                                evidence: [ { "date" => Date.current.iso8601, "source" => "duck", "section" => "code_review" } ])
  end

  def start_over_and_resubmit(exercise)
    start_over_unreviewed(DailyExercise.find(exercise.id))
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: { "code_review" => "New answer." },
                          submitted_at: Time.current, ai_review: { "code_review" => { "rating" => "solid" } })
  end

  def run(exercise, response_id)
    described_class.perform_now(user_id: user.id, daily_exercise_id: exercise.id, daily_response_id: response_id, run: "fallback")
  end

  it "leaves the replacement's ledger open when Start over lands after the merge returns" do
    exercise = submitted_set
    old_response_id = exercise.daily_response.id
    allow(LearnerItem).to receive(:merge!).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap { start_over_and_resubmit(exercise) }
    end

    run(exercise, old_response_id)

    expect(LearnerExtraction.for(exercise.reload)).to have_attributes(closed?: false, attempts: 0)
  end

  it "counts no attempt on the replacement's ledger when Start over lands after the ledger was read" do
    exercise = submitted_set
    old_response_id = exercise.daily_response.id
    allow(DuckThread).to receive(:for).and_wrap_original do |original, *args|
      start_over_and_resubmit(exercise)
      original.call(*args)
    end

    run(exercise, old_response_id)

    expect(LearnerExtraction.for(exercise.reload)).to have_attributes(closed?: false, attempts: 0)
  end

  it "writes no item when a second Delete all lands during the call in the same second as the first" do
    travel_to(Time.utc(2026, 11, 16, 15, 0, 0, 100_000), with_usec: true)
    exercise = submitted_set
    DuckThread.create!(user: user, daily_exercise: exercise, draft_scope: exercise.draft_scope,
                       threads: { "code_review" => { "turns" => [ { "role" => "user", "content" => "What does sum do?" },
                                                                  { "role" => "assistant", "content" => "Look." } ],
                                                     "version" => 1 } })
    LearnerNote.remove_all!(user)
    allow_any_instance_of(FakeService).to receive(:extract_learner_items) do
      travel(0.3.seconds, with_usec: true)
      LearnerNote.remove_all!(user)
      LearnerItemsReply::Result.new(items: [ duck_item ], dropped: {})
    end

    run(exercise.reload, exercise.daily_response.id)

    expect(LearnerItem.where(user_id: user.id)).to be_empty
  end

  it "writes no item when Delete all lands after the run read a set with no ledger yet" do
    exercise = submitted_set
    expect(exercise.plan_notes).not_to have_key(LearnerExtraction::KEY)
    allow(DuckThread).to receive(:for).and_wrap_original do |original, *args|
      LearnerNote.remove_all!(user)
      original.call(*args)
    end

    run(exercise, exercise.daily_response.id)

    expect(LearnerItem.where(user_id: user.id)).to be_empty
  end
end
