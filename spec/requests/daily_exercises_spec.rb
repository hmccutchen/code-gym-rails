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
  end
end
