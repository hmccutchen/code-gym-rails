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
    LearnerExtraction.count_attempt!(exercise, close: true, response_id: exercise.daily_response.id) if extracted
    LearnerNote.create!(user: user, daily_exercise: exercise, body: "The loop confused me.", question_key: "hardest",
                        explain_section: "code_review", explain_concept: "n_plus_one", explain_phrasing: "explain.first",
                        explanation: "It runs one query per row.")
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
      other_day: item("memoization", [ reference(today - 1, "note"), reference(today, "explanation", "code_review") ]),
      duck_only: item("scope_chaining", [ reference(today, "duck", "code_review"), reference(today, "answer", "code_review") ]),
      earlier_note: item("caching", [ reference(today - 1, "note") ]) }
  end

  def expect_the_days_note_forgotten(exercise, items)
    expect(LearnerNote.where(daily_exercise: exercise)).to be_empty
    expect(LearnerItem.where(id: items.values.map(&:id)).pluck(:concept)).to contain_exactly("scope_chaining", "caching")
    expect(LearnerExtraction.for(exercise.reload)).to have_attributes(attempts: 0, closed?: false)
  end

  describe "Start over" do
    it "deletes the day's note, every item citing it or the explanation, and the set's extraction counts" do
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

  describe "a page rendered before Start over" do
    def save_note(response_id)
      patch learner_note_path, params: { learner_note: "The old tab's note.", draft_scope: user.daily_exercises.sole.draft_scope,
                                         response_id: response_id }, as: :json
    end

    it "has its note save refused with the refresh text, since the set keeps its draft scope" do
      exercise = todays_set(submitted: false)
      old_response = exercise.daily_response
      login_as(user)
      delete start_over_response_path(old_response)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: { "code_review" => "new" })

      save_note(old_response.id)

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to eq(I18n.t("flash.responses.stale_answers"))
      expect(LearnerNote.where(daily_exercise: exercise)).to be_empty
    end

    it "has its note save refused when Start over left no response at all" do
      exercise = todays_set(submitted: false)
      old_response = exercise.daily_response
      login_as(user)
      delete start_over_response_path(old_response)

      save_note(old_response.id)

      expect(response).to have_http_status(:conflict)
      expect(LearnerNote.where(daily_exercise: exercise)).to be_empty
    end

    it "still saves a note from the page showing the current response, or rendered before any response existed" do
      exercise = todays_set(submitted: false)
      login_as(user)

      save_note(exercise.daily_response.id)
      expect(response).to have_http_status(:ok)

      save_note("")
      expect(response).to have_http_status(:ok)
    end

    it "renders on each box the response it was rendered for, or none" do
      exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago, language: "ruby_rails",
                                       problem_set: problem_set)
      login_as(user)

      get root_path
      expect(Nokogiri::HTML(response.body).at_css("#learner-note")["data-learner-note-response-id-value"]).to eq("")

      submitted = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: { "code_review" => "a" * 20 },
                                        section_ratings: { "code_review" => "right_level" }, submitted_at: Time.current)
      get root_path
      box = Nokogiri::HTML(response.body).at_css("#learner-explanation")
      expect(box["data-learner-explanation-response-id-value"]).to eq(submitted.id.to_s)
    end

    it "has an old explanation refused after Start over and a second submission" do
      exercise = todays_set
      old_response = exercise.daily_response
      login_as(user)
      delete start_over_response_path(old_response)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: { "code_review" => "a" * 20 },
                            section_ratings: { "code_review" => "right_level" }, submitted_at: Time.current)

      post learner_explanation_path, params: { section: "code_review", explanation: "The old tab's words.",
                                               draft_scope: exercise.reload.draft_scope, response_id: old_response.id }, as: :json

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to eq(I18n.t("flash.responses.stale_answers"))
      expect(LearnerNote.where(daily_exercise: exercise)).to be_empty
    end
  end

  describe "regenerating the set" do
    def stub_new_set
      service = instance_double(ClaudeService)
      allow(AiService).to receive(:for).with(user).and_return(service)
      allow(service).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:, **|
        judged = AiService::JudgedSet.new(problem_set: problem_set("A new bug").slice("code_review"), dropped_sections: [], outcomes: {}, plan_notes: {})
        with_practice_context(judged, user: caller, language: language, schedule_context: schedule_context)
      end
      allow(service).to receive(:model_for).and_return("model")
    end

    it "deletes the note of a submitted set whose extraction already ran, and every item citing it or the explanation" do
      exercise = todays_set(regenerating_since: Time.current)
      note_on(exercise)
      items = items_from_the_day
      stub_new_set

      RegenerateExerciseJob.new.perform(user_id: user.id)

      expect(exercise.reload.problem_set.dig("code_review", "question")).to eq("A new bug")
      expect(exercise.active_section_keys).to eq([ "code_review" ])
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

      expect(LearnerExtraction.for(exercise.reload)).to have_attributes(attempts: 0, closed?: false)
    end
  end
end
