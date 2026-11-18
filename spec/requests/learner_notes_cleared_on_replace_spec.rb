require "rails_helper"

RSpec.describe "A replaced set starts with no learner note", type: :request do
  include PracticeGenerationHelpers
  include ActiveJob::TestHelper

  let(:user) do
    create_user_with_key(email: "replaced-note@example.com").tap { |owner| owner.update!(learner_notes_enabled: true) }
  end

  before { stub_env("LEARNER_NOTES" => "1") }

  around { |example| travel_to(Time.utc(2026, 11, 18, 15)) { example.run } }

  def problem_set(question = "Find the bug")
    { "code_review" => { "question" => question, "snippet" => "def a; end", "concept" => "n_plus_one" },
      "pattern"     => { "title" => "Service Objects", "question" => "When?", "concept" => "service_objects" } }
  end

  def todays_set(submitted: true, **extra)
    exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago, language: "ruby_rails",
                                     problem_set: problem_set, **extra)
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "a" * 20, "pattern" => "b" * 20 },
                          section_ratings: { "code_review" => "right_level", "pattern" => "right_level" },
                          submitted_at: (Time.current if submitted))
    exercise
  end

  def note_on(exercise, extracted: true)
    LearnerNote.create!(user: user, daily_exercise: exercise, body: "The loop confused me.", question_key: "hardest",
                        explain_section: "code_review", explain_concept: "n_plus_one", explain_phrasing: "explain.first",
                        explanation: "It runs one query per row.", extract_attempts: extracted ? 1 : 0,
                        extracted_at: (Time.current if extracted))
  end

  def reference(date, source, section = nil)
    { "date" => date.iso8601, "source" => source, "section" => section }.compact
  end

  def item(concept, evidence, kind: "concept")
    LearnerItem.create!(user: user, concept: concept, bucket: "ruby_rails", kind: kind, label: "About #{concept}.",
                        evidence: evidence, came_up_on: evidence.map { |ref| ref["date"] }.uniq,
                        expires_on: Date.current + 14)
  end

  def items_from_the_day
    today = Date.current
    { only_note: item("n_plus_one", [ reference(today, "note"), reference(today, "explanation", "code_review") ]),
      with_duck: item("service_objects", [ reference(today, "note"), reference(today, "duck", "code_review") ]),
      other_day: item("memoization", [ reference(today - 1, "note"), reference(today, "explanation", "code_review") ]) }
  end

  def expect_the_days_note_forgotten(exercise, items)
    today = Date.current.iso8601
    expect(LearnerNote.where(daily_exercise: exercise)).to be_empty
    expect(LearnerItem.exists?(items[:only_note].id)).to be(false)
    expect(items[:with_duck].reload.evidence).to eq([ reference(Date.current, "duck", "code_review") ])
    expect(items[:other_day].reload.evidence).to eq([ { "date" => (Date.current - 1).iso8601, "source" => "note" } ])
    expect(LearnerItem.all.flat_map(&:evidence)).not_to include(hash_including("date" => today, "source" => "note"))
  end

  describe "Start over" do
    it "deletes the day's note and that date's note and explanation evidence, keeping items with other evidence" do
      exercise = todays_set
      note_on(exercise)
      items = items_from_the_day
      login_as(user)

      delete start_over_response_path(exercise.daily_response)

      expect(response).to redirect_to(root_path)
      expect(DailyResponse.where(daily_exercise: exercise)).to be_empty
      expect_the_days_note_forgotten(exercise, items)
    end

    it "keeps the note when the set is being reviewed and start over is refused" do
      exercise = todays_set
      exercise.daily_response.update!(reviewing_since: Time.current)
      note = note_on(exercise)
      items = items_from_the_day
      login_as(user)

      delete start_over_response_path(exercise.daily_response)

      expect(LearnerNote.exists?(note.id)).to be(true)
      expect(LearnerItem.count).to eq(items.size)
    end

    it "keeps the note when clearing the answers fails, since all three change together" do
      exercise = todays_set
      note = note_on(exercise)
      items = items_from_the_day
      allow_any_instance_of(DailyResponse).to receive(:destroy!).and_raise(ActiveRecord::RecordNotDestroyed)
      login_as(user)

      expect { delete start_over_response_path(exercise.daily_response) }.to raise_error(ActiveRecord::RecordNotDestroyed)

      expect(DailyResponse.where(daily_exercise: exercise)).to exist

      expect(LearnerNote.exists?(note.id)).to be(true)
      expect(items[:only_note].reload.evidence.size).to eq(2)
    end
  end

  describe "regenerating the set" do
    def stub_new_set
      service = instance_double(ClaudeService)
      allow(AiService).to receive(:for).with(user).and_return(service)
      allow(service).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:, **|
        judged = AiService::JudgedSet.new(problem_set: problem_set("A new bug"), dropped_sections: [], outcomes: {}, plan_notes: {})
        with_practice_context(judged, user: caller, language: language, schedule_context: schedule_context)
      end
      allow(service).to receive(:model_for).and_return("model")
    end

    it "deletes the note of a submitted set whose extraction already ran, and that date's note and explanation evidence" do
      exercise = todays_set(regenerating_since: Time.current)
      note_on(exercise)
      items = items_from_the_day
      stub_new_set

      RegenerateExerciseJob.new.perform(user_id: user.id)

      expect(exercise.reload.problem_set.dig("code_review", "question")).to eq("A new bug")
      expect_the_days_note_forgotten(exercise, items)
    end

    it "keeps the note when the replacement is not written" do
      exercise = todays_set(regenerating_since: Time.current)
      note = note_on(exercise)
      items = items_from_the_day
      stub_new_set
      allow_any_instance_of(DailyExercise).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)
      allow(Rails.logger).to receive(:error)

      RegenerateExerciseJob.new.perform(user_id: user.id)

      expect(LearnerNote.exists?(note.id)).to be(true)
      expect(items[:only_note].reload.evidence.size).to eq(2)
    end

    it "gives a page still showing the old set the refresh refusal for the note and the explanation" do
      exercise = todays_set(submitted: false, regenerating_since: Time.current)
      old_scope = exercise.draft_scope
      stub_new_set
      RegenerateExerciseJob.new.perform(user_id: user.id)
      login_as(user)

      patch learner_note_path, params: { learner_note: "Written on the old page.", draft_scope: old_scope }, as: :json
      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to eq(I18n.t("flash.responses.stale_answers"))

      exercise.reload.create_daily_response!(user: user, date: Date.current, submitted_at: Time.current,
                                             answers: { "code_review" => "a" * 20 })
      post learner_explanation_path, params: { section: "code_review", explanation: "Old words.", draft_scope: old_scope }, as: :json
      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to eq(I18n.t("flash.responses.stale_answers"))
      expect(LearnerNote.where(daily_exercise: exercise).where.not(body: nil).or(LearnerNote.where.not(explanation: nil))).to be_empty
    end

    it "leaves a fallback queued for the old set without a call, so the new set's own extraction still runs" do
      exercise = todays_set(regenerating_since: Time.current)
      old_response = exercise.daily_response
      stub_new_set
      RegenerateExerciseJob.new.perform(user_id: user.id)
      exercise.reload.create_daily_response!(user: user, date: Date.current, submitted_at: Time.current,
                                             answers: { "code_review" => "a" * 20 })
      LearnerNote.create!(user: user, daily_exercise: exercise, body: "A note on the new set.")

      ExtractLearnerItemsJob.perform_now(user_id: user.id, daily_exercise_id: exercise.id, daily_response_id: old_response.id,
                                         run: "fallback")

      expect(LearnerNote.find_by(daily_exercise: exercise)).to have_attributes(extract_attempts: 0, extracted_at: nil)
    end
  end
end
