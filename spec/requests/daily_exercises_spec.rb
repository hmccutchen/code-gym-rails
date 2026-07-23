require "rails_helper"

RSpec.describe "DailyExercises", type: :request do
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

    it "replaces the problem_set, sets regenerated_at, and destroys the existing response" do
      exercise = create_exercise
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 })

      fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => { "question" => "new" } })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post regenerate_path

      exercise.reload
      expect(exercise.problem_set).to eq("code_review" => { "question" => "new" })
      expect(exercise.regenerated_at).to be_present
      expect(exercise.daily_response).to be_nil
      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq("New set generated!")
    end

    it "regenerates using the exercise's own stored language, not the user's current mixed alternation" do
      user.update!(language: "mixed")
      exercise = create_exercise
      exercise.update!(language: "javascript")

      fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => { "question" => "new" } })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post regenerate_path

      expect(fake_service).to have_received(:generate_exercise).with(user, language: "javascript")
      expect(exercise.reload.language).to eq("javascript")
    end

    it "blocks a second regeneration the same day" do
      create_exercise(regenerated_at: Time.current)

      post regenerate_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("You've already generated a new set today.")
    end

    it "redirects with an alert when the provider raises" do
      exercise = create_exercise
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:generate_exercise).and_raise(AiService::Error, "rate limited")
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post regenerate_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("Couldn't generate a new set: rate limited")
      expect(exercise.reload.regenerated_at).to be_nil
    end

    it "shows a Settings-pointing alert without leaking the provider message when the provider raises AuthenticationError" do
      create_exercise
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:generate_exercise).and_raise(AiService::AuthenticationError, "invalid x-api-key")
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post regenerate_path

      expect(flash[:alert]).to eq("Your API key was rejected — check it in Settings.")
      expect(flash[:alert]).not_to include("x-api-key")
    end

    it "shows a try-again alert when the provider raises RateLimitError" do
      create_exercise
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:generate_exercise).and_raise(AiService::RateLimitError, "rate limited")
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post regenerate_path

      expect(flash[:alert]).to eq("The AI provider is rate-limiting requests — try again shortly.")
    end

    it "preserves the existing DailyResponse when the AI call fails" do
      exercise = create_exercise
      daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                              answers: { "code_review" => "important work" })

      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:generate_exercise).and_raise(AiService::Error, "timeout")
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post regenerate_path

      expect(DailyResponse.exists?(daily_response.id)).to be(true)
      expect(daily_response.reload.answers).to eq("code_review" => "important work")
    end

    it "does not destroy the existing DailyResponse when exercise.update! fails" do
      exercise = create_exercise
      daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                              answers: { "code_review" => "important work" })

      # A nil problem_set fails DailyExercise's presence validation, forcing
      # exercise.update! to raise ActiveRecord::RecordInvalid inside the transaction.
      fake_service = instance_double(ClaudeService, generate_exercise: nil)
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post regenerate_path

      expect(DailyResponse.exists?(daily_response.id)).to be(true)
      expect(daily_response.reload.answers).to eq("code_review" => "important work")
      expect(exercise.reload.regenerated_at).to be_nil
      expect(exercise.problem_set).to eq("code_review" => { "question" => "old" })
    end
  end

  describe "POST /generate" do
    include ActiveJob::TestHelper

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
