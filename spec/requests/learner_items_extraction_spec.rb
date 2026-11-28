require "rails_helper"

RSpec.describe "When learner items are extracted", type: :request do
  let(:user) { create_user_with_key(email: "extraction@example.com").tap { |owner| owner.update!(learner_notes_enabled: true) } }

  before do
    stub_env("LEARNER_NOTES" => "1")
    login_as(user)
  end

  around { |example| travel_to(Time.utc(2026, 11, 18, 15)) { example.run } }

  def extraction_runs = enqueued_jobs.select { |job| job["job_class"] == "ExtractLearnerItemsJob" }.map { |job| job["arguments"].first["run"] }

  def todays_set(tags = { "code_review" => "n_plus_one", "pattern" => "service_objects" })
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => tags["code_review"] },
                                         "pattern" => { "title" => "Service Objects", "question" => "When?", "concept" => tags["pattern"] } })
  end

  def submit
    exercise = user.daily_exercises.find_by!(date: Date.current)
    post responses_path, params: { response: { answers: { code_review: "It loads per row.", pattern: "" },
                                               section_ratings: { code_review: "right_level" }, draft_scope: exercise.draft_scope, manifest_revision: exercise.manifest_revision, submit: "1" } }, as: :json
  end

  describe "at submit" do
    it "schedules only the fallback on a day with a usable concept tag" do
      todays_set

      submit

      expect(response.parsed_body).to include("submitted" => true)
      expect(extraction_runs).to eq(%w[fallback])
    end

    it "also runs now on a day with no usable concept tag" do
      todays_set("code_review" => "other", "pattern" => nil)

      submit

      expect(extraction_runs).to contain_exactly("fallback", "early")
    end

    it "schedules nothing with the account's setting off, and nothing for a save that does not submit" do
      todays_set
      user.update!(learner_notes_enabled: false)
      submit
      user.update!(learner_notes_enabled: true)
      post responses_path, params: { response: { answers: { code_review: "Again." } } }, as: :json

      expect(extraction_runs).to eq([])
    end
  end

  describe "at the explanation's save" do
    def save_explanation(text)
      post learner_explanation_path, params: { section: "code_review", explanation: text,
                                               draft_scope: user.daily_exercises.sole.draft_scope,
                                               response_id: user.daily_exercises.sole.daily_response.id }, as: :json
    end

    before do
      todays_set
      submit
      clear_enqueued_jobs
    end

    it "runs the early extraction once the explanation is saved" do
      save_explanation("One query per row.")

      expect(response).to have_http_status(:ok)
      expect(extraction_runs).to eq(%w[early])
    end

    it "refuses a second save after a failed early run, enqueues nothing, and leaves the last call to the fallback" do
      save_explanation("One query per row.")
      exercise = user.daily_exercises.sole
      allow_any_instance_of(AiService).to receive(:extract_learner_items).and_raise(ProviderError::TimeoutError.new("slow"))
      ExtractLearnerItemsJob.perform_now(user_id: user.id, daily_exercise_id: exercise.id,
                                         daily_response_id: exercise.daily_response.id, run: "early")
      clear_enqueued_jobs

      save_explanation("Second words.")

      note = LearnerNote.find_by(daily_exercise: exercise)
      expect(response).to have_http_status(:conflict)
      expect(note).to have_attributes(explanation: "One query per row.")
      expect(LearnerExtraction.for(exercise.reload)).to have_attributes(attempts: 1, closed?: false)
      expect(extraction_runs).to eq([])

      calls = 0
      allow_any_instance_of(AiService).to receive(:extract_learner_items) do
        calls += 1
        LearnerItemsReply::Result.new(items: [], dropped: {})
      end
      2.times do
        ExtractLearnerItemsJob.perform_now(user_id: user.id, daily_exercise_id: exercise.id,
                                           daily_response_id: exercise.daily_response.id, run: "fallback")
      end

      expect(calls).to eq(1)
      expect(LearnerExtraction.for(exercise.reload)).to have_attributes(attempts: 2, closed?: true)
    end

    it "enqueues nothing for a save the closed box refuses" do
      LearnerExtraction.close!(user.daily_exercises.sole, response_id: user.daily_exercises.sole.daily_response.id)

      save_explanation("Too late.")

      expect(response).to have_http_status(:conflict)
      expect(extraction_runs).to eq([])
    end
  end
end
