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

  describe "POST /responses section_ratings + feedback_text" do
    let(:section) { { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } } }

    it "saves section_ratings and feedback_text from an auto-save payload" do
      create_exercise(section)

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 },
                              section_ratings: { code_review: "right_level" },
                              feedback_text: "more SQL please" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      resp = DailyResponse.last
      expect(resp.section_ratings).to eq("code_review" => "right_level")
      expect(resp.feedback_text).to eq("more SQL please")
    end

    it "merges set-only: a later payload never clears an already-saved section rating" do
      exercise = create_exercise(section)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: {}, section_ratings: { "code_review" => "too_easy" })

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 }, section_ratings: {} } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(DailyResponse.last.section_ratings).to eq("code_review" => "too_easy")
    end

    it "ignores a value outside the self-rating set instead of raising" do
      create_exercise(section)

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 },
                              section_ratings: { code_review: "bogus" } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(DailyResponse.last.section_ratings).to eq({})
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

    it "refuses to review an unsubmitted draft and sends the user back to the form" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } },
        generated_at: Time.current
      )
      draft = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                    answers: { "code_review" => "a" * 20 }, submitted_at: nil)
      expect(AiService).not_to receive(:for)

      post review_response_path(draft)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("Submit your answers first.")
      expect(draft.reload.ai_review).to be_nil
    end

    it "does not re-review an already-reviewed day, and lands on its history entry" do
      daily_response = create_submitted_response
      daily_response.update!(ai_review: { "code_review" => { "rating" => "solid" } })
      expect(AiService).not_to receive(:for)

      post review_response_path(daily_response)

      expect(response).to redirect_to(history_path(anchor: "response-#{daily_response.id}"))
      expect(flash[:notice]).to eq("Already reviewed.")
      expect(daily_response.reload.ai_review).to eq("code_review" => { "rating" => "solid" })
    end

    it "saves the ai_review from the user's configured provider" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_return("code_review" => { "rating" => "solid" })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(response).to redirect_to(history_path(anchor: "response-#{daily_response.id}"))
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

    it "shows a Settings-pointing alert without leaking the provider message when the provider raises AuthenticationError" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_raise(AiService::AuthenticationError, "invalid x-api-key")
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(flash[:alert]).to eq("Your API key was rejected — check it in Settings.")
      expect(flash[:alert]).not_to include("x-api-key")
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

  describe "POST /responses/:id/review mastery write" do
    let(:section) { { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } } }

    def submitted_response
      exercise = create_exercise(section)
      user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
        section_ratings: { "code_review" => "too_hard" },
        concept_tags: { "code_review" => "n_plus_one" })
    end

    before do
      fake = instance_double(ClaudeService, review_response: {
        "code_review" => { "rating" => "developing", "correct" => "ok",
                           "missed" => "", "better_questions" => "", "next_step" => "", "improved_code" => "" }
      })
      allow(AiService).to receive(:for).and_return(fake)
    end

    it "writes ConceptMastery state in the same transaction as the review" do
      resp = submitted_response
      post review_response_path(resp)

      expect(resp.reload.ai_review).to be_present
      expect(user.concept_masteries.find_by(concept: "n_plus_one", language: "ruby_rails")).to be_present
    end

    it "rolls back the review if the mastery write fails" do
      resp = submitted_response
      allow(ConceptMastery).to receive(:record_review!).and_raise(ActiveRecord::RecordInvalid.new(ConceptMastery.new))

      post review_response_path(resp)

      expect(resp.reload.ai_review).to be_nil
    end
  end

  describe "POST /responses/:id/review concurrent-claim guard" do
    def submitted_response(reviewing_since: nil)
      exercise = create_exercise("code_review" => { "question" => "q", "snippet" => "s" })
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
                            reviewing_since: reviewing_since)
    end

    it "refuses to start a second review while one is already in flight" do
      resp = submitted_response(reviewing_since: Time.current)
      expect(AiService).not_to receive(:for)

      post review_response_path(resp)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("A review is already being generated for this — check back in a moment.")
      expect(resp.reload.ai_review).to be_nil
      expect(resp.reviewing_since).to be_present
    end

    it "reclaims the review after the in-flight marker goes stale" do
      resp = submitted_response(reviewing_since: 10.minutes.ago)
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_return("code_review" => { "rating" => "solid" })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(resp)

      expect(response).to redirect_to(history_path(anchor: "response-#{resp.id}"))
      expect(resp.reload.ai_review).to eq("code_review" => { "rating" => "solid" })
      expect(resp.reviewing_since).to be_nil
    end

    it "clears the claim on success so a stray marker never lingers" do
      resp = submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_return("code_review" => { "rating" => "solid" })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(resp)

      expect(resp.reload.reviewing_since).to be_nil
    end

    it "clears the claim when the provider raises, so an immediate retry can proceed" do
      resp = submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_response).and_raise(AiService::Error, "boom")
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(resp)

      expect(resp.reload.reviewing_since).to be_nil
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

  describe "POST /responses redirect targets on final submit" do
    it "returns the dashboard URL in the JSON redirect key on submit" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" })

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 }, submit: "1" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(JSON.parse(response.body)["redirect"]).to eq(root_path)
    end

    it "does not include a redirect key on a non-submitting auto-save" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" })

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(JSON.parse(response.body)).not_to have_key("redirect")
    end

    it "redirects a native (no-JS) final submit back to the dashboard" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" })

      post responses_path, params: { response: { answers: { code_review: "a" * 20 }, submit: "1" } }

      expect(response).to redirect_to(root_path)
    end
  end
end
