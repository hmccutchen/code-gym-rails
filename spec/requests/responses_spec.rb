require "rails_helper"

RSpec.describe "Responses", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  def create_exercise(problem_set)
    DailyExercise.create!(user: user, date: Date.current,
                          problem_set: problem_set, generated_at: Time.current)
  end

  describe "POST /responses concept_tags copy" do
    it "copies each section's concept from the exercise onto the response" do
      create_exercise(
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern" => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "challenge" => { "title" => "t", "question" => "q", "concept" => "service_objects" }
      )

      post responses_path, params: { response: { answers: { code_review: "a" * 20 } } }

      expect(response).to have_http_status(:ok)
      expect(DailyResponse.last.concept_tags).to eq(
        "code_review" => "n_plus_one", "pattern" => "memoization", "challenge" => "service_objects"
      )
    end

    it "stores an empty map for exercises that predate tagging" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" },
                      "pattern" => { "title" => "t", "why" => "w", "question" => "q" },
                      "challenge" => { "title" => "t", "question" => "q" })

      post responses_path, params: { response: { answers: { code_review: "a" * 20 } } }

      expect(DailyResponse.last.concept_tags).to eq({})
    end
  end
end
