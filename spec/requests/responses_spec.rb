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

    it "tags and saves an architecture third section's concept and answer" do
      create_exercise(
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "architecture" => { "title" => "t", "question" => "q", "concept" => "service_boundaries" }
      )

      post responses_path,
        params: { response: { answers: { architecture: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      resp = DailyResponse.last
      expect(resp.answers["architecture"]).to eq("a" * 20)
      expect(resp.concept_tags).to eq(
        "code_review" => "n_plus_one", "pattern" => "memoization", "architecture" => "service_boundaries"
      )
    end

    it "ignores an answer for a third section this exercise does not have" do
      create_exercise(
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "architecture" => { "title" => "t", "question" => "q", "concept" => "service_boundaries" }
      )

      post responses_path,
        params: { response: { answers: { architecture: "a" * 20, challenge: "b" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      resp = DailyResponse.last
      expect(resp.answers).to have_key("architecture")
      expect(resp.answers).not_to have_key("challenge")
      expect(resp.completeness).to be <= 100
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

  describe "POST /responses rating + feedback_text" do
    let(:section) { { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } } }

    it "saves rating and feedback_text from an auto-save payload" do
      create_exercise(section)

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 },
                              rating: "right_level", feedback_text: "more SQL please" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      resp = DailyResponse.last
      expect(resp.rating).to eq("right_level")
      expect(resp.feedback_text).to eq("more SQL please")
      expect(resp.submitted_at).to be_nil
    end

    it "saves rating alongside answers on final submit" do
      create_exercise(section)

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 }, rating: "too_hard", submit: "1" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      resp = DailyResponse.last
      expect(resp.rating).to eq("too_hard")
      expect(resp.submitted_at).to be_present
    end

    it "does not clear an existing rating when the payload omits the key" do
      exercise = create_exercise(section)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: {}, rating: :too_easy, feedback_text: "keep me")

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      resp = DailyResponse.last
      expect(resp.rating).to eq("too_easy")
      expect(resp.feedback_text).to eq("keep me")
    end

    it "ignores a rating value outside the enum instead of raising" do
      create_exercise(section)

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 }, rating: "bogus" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(DailyResponse.last.rating).to be_nil
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

      expect(response).to redirect_to(response_path(daily_response))
      expect(flash[:alert]).to eq("No review to email yet.")
    end

    it "enqueues the review email and confirms with the user's address" do
      daily_response = create_reviewed_response(user)

      expect {
        post email_review_response_path(daily_response)
      }.to have_enqueued_mail(ReviewMailer, :send_review).with(daily_response)

      expect(response).to redirect_to(response_path(daily_response))
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

      expect(response).to redirect_to(response_path(daily_response))
      expect(daily_response.reload.ai_review).to eq("code_review" => { "rating" => "solid" })
    end

    it "redirects with an alert when the provider raises" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_raise(AiService::Error, "rate limited")
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(response).to redirect_to(response_path(daily_response))
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

    it "enqueues the architecture concept under the 'architecture' language bucket" do
      create_exercise(
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "architecture" => { "title" => "t", "question" => "q", "concept" => "service_boundaries" }
      )

      expect {
        post responses_path,
          params: { response: { answers: { code_review: "a" * 20 }, submit: "1" } }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.to have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "service_boundaries", language: "architecture", user_id: user.id)
        .exactly(:once)
        .and have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
        .exactly(:once)
    end
  end

  describe "GET /responses/:id (review page)" do
    def submitted_response_for(owner)
      exercise = DailyExercise.create!(
        user: owner, date: Date.current, generated_at: Time.current,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
                       "pattern" => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
                       "challenge" => { "title" => "t", "question" => "q", "concept" => "service_objects" } }
      )
      DailyResponse.create!(user: owner, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
    end

    it "renders the current user's own submitted response" do
      resp = submitted_response_for(user)

      get response_path(resp)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("✓ Submitted")
    end

    it "404s for another user's response id (owner scoping)" do
      other = create_user_with_key(email: "other@example.com", name: "Other")
      resp = submitted_response_for(other)

      get response_path(resp)

      expect(response).to have_http_status(:not_found)
    end

    it "renders a section's concept-reference dropdown on the review page when one is cached" do
      resp = submitted_response_for(user)
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               tagline: "Avoid the loop query", explanation: "e", code_example: "c", senior_lens: "l")

      get response_path(resp)

      expect(response.body).to include("Reference — N plus one: how it works")
      expect(response.body).to include("Avoid the loop query")
    end

    it "renders no concept-reference dropdown on the review page when none is cached" do
      resp = submitted_response_for(user)

      get response_path(resp)

      expect(response.body).not_to include("Reference — N plus one: how it works")
    end

    it "renders a submitted architecture answer read-only on the review page" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
          "pattern"     => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
          "architecture" => { "title" => "Datastore", "scenario" => "10x traffic", "question" => "Pick",
                              "options" => [ "Shard", "Cache" ], "concept" => "scaling_bottlenecks",
                              "reference" => { "tagline" => "t", "explanation" => "e",
                                               "tradeoffs" => [ "a", "b" ], "senior_lens" => "l" } }
        })
      resp = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                   answers: { "architecture" => "I would shard because scale" }, submitted_at: Time.current)

      get response_path(resp)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("I would shard because scale")
      expect(response.body).to include("10x traffic")
    end

    it "redirects a still-unsubmitted draft away from the review page" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } }
      )
      draft = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                    answers: { "code_review" => "a" * 20 }, submitted_at: nil)

      get response_path(draft)

      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST /responses redirect targets on final submit" do
    it "returns the review-page URL in the JSON redirect key on submit" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" })

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 }, submit: "1" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(JSON.parse(response.body)["redirect"]).to eq(response_path(DailyResponse.last))
    end

    it "does not include a redirect key on a non-submitting auto-save" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" })

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(JSON.parse(response.body)).not_to have_key("redirect")
    end

    it "redirects a native (no-JS) final submit to the review page" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" })

      post responses_path, params: { response: { answers: { code_review: "a" * 20 }, submit: "1" } }

      expect(response).to redirect_to(response_path(DailyResponse.last))
    end
  end
end
