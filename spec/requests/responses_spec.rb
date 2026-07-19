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

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(DailyResponse.last.concept_tags).to eq(
        "code_review" => "n_plus_one", "pattern" => "memoization", "challenge" => "service_objects"
      )
    end

    it "stores an empty map for exercises that predate tagging" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" },
                      "pattern" => { "title" => "t", "why" => "w", "question" => "q" },
                      "challenge" => { "title" => "t", "question" => "q" })

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(DailyResponse.last.concept_tags).to eq({})
    end
  end

  describe "POST /responses re-submission of a persisted draft" do
    it "updates the same record and submits it, without needing a PATCH route" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" })

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(DailyResponse.count).to eq(1)

      post responses_path,
        params: { response: { answers: { code_review: "b" * 20 }, submit: "1" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(DailyResponse.count).to eq(1)
      expect(DailyResponse.last.answers["code_review"]).to eq("b" * 20)
      expect(DailyResponse.last.submitted_at).to be_present
    end
  end

  describe "POST /responses format handling" do
    it "returns JSON for the JS auto-save/submit fetch calls (Accept: application/json)" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" })

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response.media_type).to eq("application/json")
      expect(JSON.parse(response.body)).to include("status" => "saved")
    end

    it "redirects instead of dumping raw JSON when the browser submits the form natively (no JS)" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" })

      post responses_path, params: { response: { answers: { code_review: "a" * 20 } } }

      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST /responses/:id/email_review" do
    def create_reviewed_response(owner, reviewed: true)
      exercise = DailyExercise.create!(
        user: owner, date: Date.current,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } },
        generated_at: Time.current
      )
      DailyResponse.create!(
        user: owner, daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "a" * 20 },
        submitted_at: Time.current,
        ai_review: reviewed ? { "code_review" => { "rating" => "solid", "correct" => "Spotted it" } } : nil
      )
    end

    it "requires login" do
      daily_response = create_reviewed_response(user)
      delete logout_path
      post email_review_response_path(daily_response)
      expect(response).to redirect_to(login_path)
    end

    it "404s for another user's response" do
      other = create_user_with_key(email: "other@example.com", name: "Other")
      daily_response = create_reviewed_response(other)

      post email_review_response_path(daily_response)

      # set_response scopes to current_user.daily_responses -> RecordNotFound,
      # which test env's show_exceptions = :rescuable renders as a 404.
      expect(response).to have_http_status(:not_found)
    end

    it "redirects with an alert when there is no review yet" do
      daily_response = create_reviewed_response(user, reviewed: false)

      expect {
        post email_review_response_path(daily_response)
      }.not_to have_enqueued_mail(ReviewMailer, :send_review)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("No review to email yet.")
    end

    it "enqueues the review email and confirms with the user's address" do
      daily_response = create_reviewed_response(user)

      expect {
        post email_review_response_path(daily_response)
      }.to have_enqueued_mail(ReviewMailer, :send_review).with(daily_response)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq("Review sent to dev@example.com.")
    end
  end

  describe "POST /responses/:id/review" do
    def create_submitted_response
      exercise = DailyExercise.create!(
        user: user, date: Date.current,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" },
                       "pattern" => { "title" => "t", "question" => "q" },
                       "challenge" => { "title" => "t", "question" => "q" } },
        generated_at: Time.current
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
    end

    it "saves the ai_review from the user's configured provider" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_return("code_review" => { "rating" => "solid" })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(response).to redirect_to(root_path)
      expect(daily_response.reload.ai_review).to eq("code_review" => { "rating" => "solid" })
    end

    it "redirects with an alert when the provider raises" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_raise(AiService::Error, "rate limited")
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("Couldn't generate the review: rate limited")
    end

    it "shows a Settings-pointing alert when the provider raises AuthenticationError" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_raise(AiService::AuthenticationError, "invalid x-api-key")
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(flash[:alert]).to eq("Your API key was rejected — check it in Settings. (invalid x-api-key)")
    end

    it "shows a try-again alert when the provider raises RateLimitError" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_raise(AiService::RateLimitError, "rate limited")
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(flash[:alert]).to eq("The AI provider is rate-limiting requests — try again shortly.")
    end
  end

  describe "POST /responses concept reference generation" do
    include ActiveJob::TestHelper

    def submit_with_concepts
      create_exercise(
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern" => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "challenge" => { "title" => "t", "question" => "q", "concept" => "n_plus_one" }
      )
      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 }, submit: "1" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    it "enqueues one job per distinct concept lacking a reference on submission" do
      expect { submit_with_concepts }
        .to have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
        .exactly(:once)
        .and have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "memoization", language: "ruby_rails", user_id: user.id)
        .exactly(:once)
    end

    it "does not enqueue for a concept that already has a reference" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "x")
      expect { submit_with_concepts }
        .not_to have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
    end

    it "does not enqueue on a non-submitting auto-save" do
      create_exercise(
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern" => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "challenge" => { "title" => "t", "question" => "q", "concept" => "service_objects" }
      )
      expect {
        post responses_path,
          params: { response: { answers: { code_review: "a" * 20 } } }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.not_to have_enqueued_job(GenerateConceptReferenceJob)
    end

    it "does not enqueue for the 'other' concept" do
      create_exercise(
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "other" },
        "pattern" => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "challenge" => { "title" => "t", "question" => "q", "concept" => "other" }
      )
      expect {
        post responses_path,
          params: { response: { answers: { code_review: "a" * 20 }, submit: "1" } }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.not_to have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "other", language: "ruby_rails", user_id: user.id)
    end
  end
end
