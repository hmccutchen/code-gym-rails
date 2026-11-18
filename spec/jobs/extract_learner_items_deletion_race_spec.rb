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
    let(:during) { ->(exercise) { exercise.reload.start_over!(exercise.daily_response) } }

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
