require "rails_helper"

RSpec.describe "DailyExercises", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create_user_with_key }

  before { login_as(user) }

  def create_exercise(regenerated_at: nil)
    DailyExercise.create!(user: user, date: Date.current,
                          problem_set: { "code_review" => { "question" => "old" } },
                          generated_at: Time.current, regenerated_at: regenerated_at)
  end

  describe "POST /regenerate" do
    it "redirects with an alert when there's no exercise yet" do
      post regenerate_path
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("No exercise set to regenerate yet.")
    end

    it "blocks a second regeneration the same day" do
      create_exercise(regenerated_at: Time.current)

      post regenerate_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("You've already generated a new set today.")
    end

    it "enqueues the job without calling the provider inline" do
      create_exercise
      allow(AiService).to receive(:for)

      expect {
        post regenerate_path
      }.to have_enqueued_job(RegenerateExerciseJob).with(user_id: user.id)

      expect(AiService).not_to have_received(:for)
      expect(response).to redirect_to(root_path)
    end

    it "claims the row so the dashboard can show it as in flight" do
      exercise = create_exercise

      post regenerate_path

      expect(exercise.reload.regenerating_since).to be_present
    end

    # An impatient second click must not enqueue a second billable generation.
    it "does not enqueue twice while a claim is already held" do
      create_exercise
      post regenerate_path

      expect { post regenerate_path }.not_to have_enqueued_job(RegenerateExerciseJob)
    end

    # A worker that died mid-job leaves a claim behind; the user must be able to
    # try again rather than being locked out for the rest of the day.
    it "lets a stale claim be reclaimed" do
      exercise = create_exercise
      exercise.update!(regenerating_since: DailyExercise::REGENERATION_STALE_AFTER.ago - 1.minute)

      expect {
        post regenerate_path
      }.to have_enqueued_job(RegenerateExerciseJob)
    end

    # The unit specs verify the controller's claim and the job's replacement
    # separately. This walks the whole loop, so a mismatch between what the
    # controller enqueues and what the job expects cannot pass unnoticed.
    it "shows the spinner until the enqueued job replaces the set" do
      exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                       problem_set: { "code_review" => { "question" => "PREVIOUS-SET-MARKER" } })

      post regenerate_path

      get root_path
      expect(response.body).to include("Generating your personalized exercise set")
      expect(response.body).not_to include("PREVIOUS-SET-MARKER")

      get dashboard_status_path
      expect(JSON.parse(response.body)["status"]).to eq("pending")

      fake_service = instance_double(ClaudeService, generate_exercise: {
                                       "code_review" => { "question" => "freshly generated", "snippet" => "def a; end" },
                                       "pattern" => {
                                         "title" => "Service Objects", "why" => "Because", "question" => "When?",
                                         "reference" => { "tagline" => "T", "explanation" => "E",
                                                          "code_example" => "code", "senior_lens" => "S" }
                                       },
                                       "challenge" => { "title" => "Build", "question" => "Implement X", "starter_code" => "" }
                                     })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)
      perform_enqueued_jobs

      expect(exercise.reload.regenerating_since).to be_nil

      get dashboard_status_path
      expect(JSON.parse(response.body)["status"]).to eq("ready")

      get root_path
      expect(response.body).to include("freshly generated")
    end
  end

  describe "POST /generate" do
    it "enqueues generation and redirects with the generating flash when there's no exercise yet" do
      expect {
        post generate_path
      }.to have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id)

      expect(response).to redirect_to(root_path)
      expect(flash[:generating]).to be true
    end

    it "no-ops if today's exercise already exists" do
      create_exercise

      expect {
        post generate_path
      }.not_to have_enqueued_job(GenerateDailyExercisesJob)

      expect(response).to redirect_to(root_path)
    end
  end
end
