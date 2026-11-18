require "rails_helper"

RSpec.describe ExtractLearnerItemsJob do
  include ActiveJob::TestHelper

  let(:user) do
    User.create!(email: "extract@example.com", time_zone: "UTC", provider: "fake", api_keys: { "fake" => "fake-key" },
                 learner_notes_enabled: true)
  end
  let(:calls) { [] }
  let(:reply) { LearnerItemsReply::Result.new(items: [], dropped: {}) }

  before do
    stub_env("LEARNER_NOTES" => "1")
    allow_any_instance_of(FakeService).to receive(:extract_learner_items) do |_service, _user, **values|
      calls << values
      reply.is_a?(Exception) ? raise(reply) : reply
    end
  end

  around { |example| travel_to(Time.utc(2026, 11, 16, 15)) { example.run } }

  def tags = { "code_review" => "n_plus_one", "pattern" => "service_objects" }

  def submitted_set(tags: self.tags, answers: { "code_review" => "It queries per row.", "pattern" => "" })
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => tags["code_review"],
                           "answer_key" => { "issue" => "KEY-TEXT" } },
        "pattern"     => { "title" => "Service Objects", "question" => "When?", "concept" => tags["pattern"] }
      }
    )
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: answers,
                          section_ratings: { "code_review" => "too_hard" }, submitted_at: Time.current,
                          ai_review: { "code_review" => { "rating" => "solid", "correct" => "REVIEW-TEXT" } })
    exercise
  end

  def with_duck_turn(exercise, text = "What does sum do here?")
    DuckThread.create!(user: user, daily_exercise: exercise, draft_scope: exercise.draft_scope,
                       threads: { "code_review" => { "turns" => [ { "role" => "user", "content" => text },
                                                                  { "role" => "assistant", "content" => "Look at the loop." } ],
                                                     "version" => 1 } })
    exercise
  end

  def explained(exercise, text = "It runs one query per row.")
    LearnerNote.create!(user: user, daily_exercise: exercise, explain_section: "code_review", explain_concept: "n_plus_one",
                        explain_phrasing: "explain.first", explanation: text)
  end

  def run(exercise, kind) = described_class.perform_now(**job_args(exercise), run: kind)

  def job_args(exercise) = { user_id: user.id, daily_exercise_id: exercise.id, daily_response_id: exercise.daily_response&.id }

  def note(exercise) = LearnerNote.find_by(daily_exercise: exercise)

  def ledger(exercise) = LearnerExtraction.for(exercise.reload)

  describe ".queue_for_submitted" do
    it "schedules only the fallback on a day with a usable tag, at the later of local midnight and an hour after submit" do
      exercise = submitted_set

      expect { described_class.queue_for_submitted(user, exercise) }.to have_enqueued_job(described_class)
        .with(**job_args(exercise), run: "fallback")
        .at(Time.utc(2026, 11, 17)).on_queue("provider_calls").exactly(:once)
      expect(enqueued_jobs.sole["priority"]).to eq(JobPriority::BACKGROUND)
    end

    it "schedules the fallback an hour after a submit made late in the evening" do
      travel_to(Time.utc(2026, 11, 16, 23, 30))

      expect { described_class.queue_for_submitted(user, submitted_set) }.to have_enqueued_job(described_class)
        .at(Time.utc(2026, 11, 17, 0, 30))
    end

    it "counts midnight in the owner's own zone" do
      user.update!(time_zone: "America/New_York")

      expect { described_class.queue_for_submitted(user, submitted_set) }.to have_enqueued_job(described_class)
        .at(Time.utc(2026, 11, 17, 5))
    end

    it "also runs now on a day with no usable concept tag" do
      exercise = submitted_set(tags: { "code_review" => "other", "pattern" => nil })

      described_class.queue_for_submitted(user, exercise)

      expect(enqueued_jobs.map { |job| job["arguments"].first["run"] }).to contain_exactly("fallback", "early")
    end

    it "queues nothing with the switch or the account's setting off" do
      exercise = submitted_set
      stub_env("LEARNER_NOTES" => nil)
      described_class.queue_for_submitted(user, exercise)
      stub_env("LEARNER_NOTES" => "1")
      user.update!(learner_notes_enabled: false)
      described_class.queue_for_submitted(user, exercise)

      expect(enqueued_jobs).to be_empty
    end

    it "queues nothing for an account with the setting on but no key of its own" do
      exercise = submitted_set
      user.update!(api_keys: nil, provider: nil)

      described_class.queue_for_submitted(user, exercise)

      expect(enqueued_jobs).to be_empty
    end
  end

  describe "what a run sends" do
    it "makes the call on an explanation-only day, and stamps it on success" do
      exercise = submitted_set
      explained(exercise)

      run(exercise, "early")

      expect(calls.size).to eq(1)
      expect(calls.sole[:explanation]).to include(section: "code_review", concept: "n_plus_one", text: "It runs one query per row.")
      expect(ledger(exercise)).to have_attributes(attempts: 1, closed?: true)
    end

    it "sends sections, answers, turns and the note as values, with no review text, answer key or rating" do
      exercise = with_duck_turn(submitted_set)
      LearnerNote.create!(user: user, daily_exercise: exercise, body: "The loop confused me.", question_key: NoteQuestion::NO_SIGNAL)

      run(exercise, "fallback")

      values = calls.sole
      expect(values[:sections].map { |section| section[:key] }).to eq(%w[code_review pattern])
      expect(values[:sections].first).to include(answer: "It queries per row.")
      expect(values[:sections].first[:turns].first).to include(content: "What does sum do here?")
      expect(values[:note]).to include(text: "The loop confused me.")
      expect(values[:day]).to have_attributes(date: Date.current, duck_sections: %w[code_review], answered_sections: %w[code_review],
                                              note: true, explanation_section: nil)
      expect(values[:buckets]).to include("ruby_rails", "architecture")
      rendered = LearnerItemsPrompt.generate(concepts: {}, **values.slice(:sections, :note, :explanation, :open_items, :earlier_items))
      expect(rendered[:prompt]).not_to include("KEY-TEXT")
      expect(rendered[:prompt]).not_to include("REVIEW-TEXT")
      expect(rendered[:prompt]).not_to include("too_hard")
    end

    it "sends open items without ids and the earlier labels from the scope" do
      exercise = with_duck_turn(submitted_set)
      LearnerItem.create!(user: user, concept: "n_plus_one", bucket: "ruby_rails", kind: "concept", label: "Practise preloading.",
                          evidence: [ { "date" => "2026-11-10", "source" => "note" } ], came_up_on: [ "2026-11-10" ],
                          expires_on: Date.new(2026, 11, 24))

      run(exercise, "fallback")

      expect(calls.sole[:open_items]).to eq([ { concept: "n_plus_one", bucket: "ruby_rails", kind: "concept", term: nil,
                                                label: "Practise preloading." } ])
      expect(calls.sole[:earlier_items]).to eq([])
    end

    it "stamps a day with no duck turn, note or explanation, with no call and no attempt" do
      exercise = submitted_set
      LearnerNote.create!(user: user, daily_exercise: exercise, body: "   ")

      run(exercise, "fallback")

      expect(calls).to be_empty
      expect(ledger(exercise)).to have_attributes(attempts: 0, closed?: true)
    end

    it "writes the items the reply returns through the merge and logs counts with no text" do
      exercise = with_duck_turn(submitted_set)
      item = LearnerItemsReply::Item.new(concept: "n_plus_one", bucket: "ruby_rails", kind: "concept", term: nil,
                                         label: "Practise preloading.", evidence: [ { "date" => "2026-11-16", "source" => "duck", "section" => "code_review" } ])
      allow_any_instance_of(FakeService).to receive(:extract_learner_items).and_return(
        LearnerItemsReply::Result.new(items: [ item ], dropped: { bad_label: 2 })
      )
      log = StringIO.new
      allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(log))

      run(exercise, "fallback")

      expect(LearnerItem.where(user: user).pluck(:label)).to eq([ "Practise preloading." ])
      expect(log.string).to include("[learner_items] user #{user.id} run=fallback written=1 absorbed=0 dropped=bad_label:2")
      expect(log.string).not_to include("Practise preloading")
    end
  end

  describe "once per set" do
    let(:exercise) { with_duck_turn(submitted_set) }

    it "makes one call for an early run and the fallback after it" do
      run(exercise, "early")
      run(exercise, "fallback")

      expect(calls.size).to eq(1)
    end

    it "makes one call for two fallbacks" do
      2.times { run(exercise, "fallback") }

      expect(calls.size).to eq(1)
    end

    it "lets the fallback call once after a failed early run, then closes the set" do
      failure = ProviderError::TimeoutError.new("slow")
      allow_any_instance_of(FakeService).to receive(:extract_learner_items) do
        calls << :called
        raise failure if calls.size == 1

        LearnerItemsReply::Result.new(items: [], dropped: {})
      end

      run(exercise, "early")
      expect(ledger(exercise)).to have_attributes(attempts: 1, closed?: false)

      run(exercise, "fallback")
      run(exercise, "fallback")

      expect(calls.size).to eq(2)
      expect(ledger(exercise)).to have_attributes(attempts: 2, closed?: true)
    end

    it "makes no call from a run that finds two attempts counted" do
      LearnerNote.create!(user: user, daily_exercise: exercise, body: "Stuck.")
      2.times { LearnerExtraction.count_attempt!(exercise, close: false, response_id: exercise.daily_response.id) }

      run(exercise, "fallback")

      expect(calls).to be_empty
      expect(ledger(exercise)).to have_attributes(attempts: 2, closed?: true)
    end

    it "makes no call for a set read before its note was deleted, and writes no note row" do
      explained(exercise)
      run(exercise, "early")
      LearnerNote.remove_all!(user)

      run(exercise, "fallback")

      expect(calls.size).to eq(1)
      expect(note(exercise)).to be_nil
    end

    it "writes no note row for a set that has none" do
      run(exercise, "fallback")

      expect(calls.size).to eq(1)
      expect(LearnerNote.where(daily_exercise: exercise)).to be_empty
      expect(ledger(exercise)).to have_attributes(attempts: 1, closed?: true)
    end

    it "does not call again when a job runs again after its worker died mid-call" do
      allow_any_instance_of(FakeService).to receive(:extract_learner_items) do
        calls << :called
        raise SignalException, "TERM"
      end

      expect { run(exercise, "early") }.to raise_error(SignalException)
      run(exercise, "early")
      expect(calls.size).to eq(1)

      expect { run(exercise, "fallback") }.to raise_error(SignalException)
      run(exercise, "fallback")
      expect(calls.size).to eq(2)
      expect(ledger(exercise)).to have_attributes(attempts: 2, closed?: true)
    end

    it "leaves generation_account_failures alone when the call fails" do
      user.update!(generation_account_failures: 1)
      allow_any_instance_of(FakeService).to receive(:extract_learner_items).and_raise(ProviderError::AuthenticationError.new("no"))

      run(exercise, "fallback")

      expect(user.reload.generation_account_failures).to eq(1)
    end
  end

  describe "a run that makes no call" do
    let(:exercise) { with_duck_turn(submitted_set) }

    def expect_closed_without_a_call(kind)
      run(exercise, kind)

      expect(calls).to be_empty
      expect(ledger(exercise)).to have_attributes(attempts: 0, closed?: true)
    end

    %w[early fallback].each do |kind|
      it "stamps the set for a held key on the #{kind} run" do
        user.update!(generation_account_failures: KeyHold::AFTER)

        expect_closed_without_a_call(kind)
      end

      it "stamps the set for a removed key on the #{kind} run" do
        user.update!(api_keys: nil, provider: nil)

        expect_closed_without_a_call(kind)
      end
    end

    it "stamps the set when the account's setting was turned off before the fallback" do
      user.update!(learner_notes_enabled: false)

      expect_closed_without_a_call("fallback")
    end

    it "stamps the set when the switch was turned off before the fallback" do
      stub_env("LEARNER_NOTES" => nil)

      expect_closed_without_a_call("fallback")
    end

    it "does nothing for an account deleted before the run" do
      exercise
      user.update_columns(anonymized_at: Time.current)

      expect { run(exercise, "fallback") }.not_to raise_error
      expect(calls).to be_empty
    end
  end

  describe "the claim" do
    it "puts a fallback that finds another run holding the set back on the queue, and makes no call" do
      exercise = with_duck_turn(submitted_set)
      allow(AdvisoryLock).to receive(:hold).and_return(false)

      expect { run(exercise, "fallback") }.to have_enqueued_job(described_class)
        .with(**job_args(exercise), run: "fallback")
      expect(calls).to be_empty
    end

    it "drops an early run that finds the set held, since the fallback still comes" do
      exercise = with_duck_turn(submitted_set)
      allow(AdvisoryLock).to receive(:hold).and_return(false)

      expect { run(exercise, "early") }.not_to have_enqueued_job(described_class)
    end
  end
end
