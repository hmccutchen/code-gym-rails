require "rails_helper"

RSpec.describe "Responses", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  def create_exercise(problem_set)
    DailyExercise.create!(user: user, date: Date.current,
                          problem_set: problem_set, generated_at: Time.current)
  end

  describe "POST /responses (parsons_problem answer)" do
    it "round-trips a parsons_problem answer through create and answered_sections" do
      exercise = create_exercise(
        "parsons_problem" => { "title" => "T", "question" => "Q", "blocks" => %w[a b c d e] }
      )

      post responses_path, params: { response: { answers: { "parsons_problem" => "order:2,0,4,1,3" } } },
           as: :json

      expect(response).to have_http_status(:ok)
      saved = DailyResponse.find_by(user: user, daily_exercise: exercise)
      expect(saved.answers["parsons_problem"]).to eq("order:2,0,4,1,3")
      expect(saved.answered_sections).to include("parsons_problem")
    end
  end

  # The point of re-dating on resume: at its original date the held set is
  # unreachable here — #create looks it up with `for_date` and 404s.
  describe "POST /responses after resuming from a pause" do
    include ActiveSupport::Testing::TimeHelpers

    it "saves against the set the resume brought forward" do
      travel_to(Time.utc(2026, 7, 22, 12)) do
        held = DailyExercise.create!(user: user, date: Date.current - 1, generated_at: Time.current,
                                     problem_set: { "code_review" => { "question" => "q" } })
        user.update!(paused_generation_at: (Date.current - 1).in_time_zone(user.effective_time_zone) + 9.hours)

        post responses_path, params: { response: { answers: { "code_review" => "a" * 20 } } }, as: :json
        expect(response).to have_http_status(:not_found)

        user.resume_generation!

        post responses_path, params: { response: { answers: { "code_review" => "a" * 20 } } }, as: :json

        expect(response).to have_http_status(:ok)
        expect(DailyResponse.find_by(user: user, daily_exercise: held)).to be_present
      end
    end
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

    it "tags and saves a security_review third section's concept and answer" do
      create_exercise(
        "code_review"      => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"          => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "security_review"  => { "title" => "t", "question" => "q", "concept" => "sql_injection_prevention" }
      )

      post responses_path,
        params: { response: { answers: { security_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      resp = DailyResponse.last
      expect(resp.answers["security_review"]).to eq("a" * 20)
      expect(resp.concept_tags).to eq(
        "code_review" => "n_plus_one", "pattern" => "memoization", "security_review" => "sql_injection_prevention"
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

    # A payload can hold more third- or fourth-shaped keys than the page ever
    # renders — FakeService returns all eight, and a provider can throw in an
    # alternate. Tagging what was never shown puts a concept the engineer
    # never saw into the history that shapes tomorrow's set.
    it "omits a section the exercise holds but never presented" do
      create_exercise(
        "code_review"  => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"      => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "architecture" => { "title" => "t", "question" => "q", "concept" => "service_boundaries" },
        "challenge"    => { "title" => "t", "question" => "q", "concept" => "service_objects" }
      )

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      resp = DailyResponse.last
      expect(resp.concept_tags.keys).to match_array(DailyExercise.last.active_section_keys)
      expect(resp.concept_tags).not_to have_key("challenge")
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
    def create_submitted_response(date: Date.current)
      exercise = DailyExercise.create!(
        user: user, date: date,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" },
                       "pattern" => { "title" => "t", "question" => "q" },
                       "challenge" => { "title" => "t", "question" => "q" } },
        generated_at: Time.current
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: date,
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

    it "does not re-review an already-reviewed day, and lands back on the dashboard" do
      daily_response = create_submitted_response
      daily_response.update!(ai_review: {
        "code_review" => { "rating" => "solid" },
        "pattern"     => { "rating" => "solid" },
        "challenge"   => { "rating" => "solid" }
      })
      expect(AiService).not_to receive(:for)

      post review_response_path(daily_response)

      expect(response).to redirect_to(root_path(anchor: "ai-review"))
      expect(flash[:notice]).to eq("Already reviewed.")
    end

    it "persists the difficulty assessment alongside the grade and renders it once reviewed" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return(
        "code_review" => { ok: true, review: { "rating" => "developing",
                                               "difficulty" => { "level" => "demanding",
                                                                 "reason" => "The extra query hides behind an association read." } } },
        "pattern"     => { ok: true, review: { "rating" => "solid" } },
        "challenge"   => { ok: true, review: { "rating" => "solid" } }
      )
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(daily_response.reload.ai_review.dig("code_review", "difficulty"))
        .to eq("level" => "demanding", "reason" => "The extra query hides behind an association read.")

      get root_path
      expect(response.body).to include("This problem was rated demanding difficulty")
      expect(response.body).to include("The extra query hides behind an association read.")
    end

    it "saves the ai_review from the user's configured provider" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return(
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "solid" } },
        "challenge"   => { ok: true, review: { "rating" => "solid" } }
      )
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(response).to redirect_to(root_path(anchor: "ai-review"))
      expect(daily_response.reload.ai_review.keys).to match_array(%w[code_review pattern challenge])
    end

    it "logs the AI rating paired with the user's self-rating for each reviewed section" do
      daily_response = create_submitted_response
      daily_response.update!(section_ratings: { "code_review" => "right_level", "pattern" => "too_hard" })
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return(
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "beginner" } },
        "challenge"   => { ok: true, review: { "rating" => "solid" } }
      )
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
      end

      post review_response_path(daily_response)

      expect(logged).not_to be_nil
      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))

      expect(payload["event"]).to eq("review")
      expect(payload["user_id"]).to eq(user.id)
      expect(payload["date"]).to eq(daily_response.date.to_s)
      expect(payload["sections"]).to eq(
        "code_review" => { "ai_rating" => "solid",    "self_rating" => "right_level" },
        "pattern"     => { "ai_rating" => "beginner", "self_rating" => "too_hard" },
        "challenge"   => { "ai_rating" => "solid",    "self_rating" => nil }
      )
    end

    it "logs the generation exercise's date, not the response's own save-time date, when they differ" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current - 1,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } },
        generated_at: Time.current
      )
      daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                             answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return(
        "code_review" => { ok: true, review: { "rating" => "solid" } }
      )
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
      end

      post review_response_path(daily_response)

      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))
      expect(payload["date"]).to eq(exercise.date.to_s)
      expect(payload["date"]).not_to eq(daily_response.date.to_s)
    end

    it "does not log when every section fails" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return(
        "code_review" => { ok: false, error_code: "rate_limit", message: "slow down" },
        "pattern"     => { ok: false, error_code: "rate_limit", message: "slow down" },
        "challenge"   => { ok: false, error_code: "rate_limit", message: "slow down" }
      )
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      expect(Rails.logger).not_to receive(:info).with(/\[difficulty_diagnostics\]/)

      post review_response_path(daily_response)
    end

    it "abandons the review without writing mastery state if the response is destroyed mid-flight" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections) do
        DailyResponse.where(id: daily_response.id).delete_all
        {
          "code_review" => { ok: true, review: { "rating" => "solid" } },
          "pattern"     => { ok: true, review: { "rating" => "solid" } },
          "challenge"   => { ok: true, review: { "rating" => "solid" } }
        }
      end
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      expect { post review_response_path(daily_response) }.not_to change(ConceptMastery, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("This set was cleared while the review was running — nothing was saved.")
      expect(DailyResponse.exists?(daily_response.id)).to be false
    end

    it "lands on the dashboard even for an entry far back in history" do
      target = create_submitted_response(date: 30.days.ago.to_date)
      (1..10).each { |i| create_submitted_response(date: i.days.ago.to_date) }
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return(
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "solid" } },
        "challenge"   => { ok: true, review: { "rating" => "solid" } }
      )
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(target)

      expect(response).to redirect_to(root_path(anchor: "ai-review"))
    end

    it "redirects with an alert when the provider raises" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return("code_review" => { ok: false, error_code: "other", message: "rate limited" })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("Couldn't generate the review: rate limited")
    end

    it "shows a Settings-pointing alert without leaking the provider message when the provider raises AuthenticationError" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return("code_review" => { ok: false, error_code: "authentication", message: "invalid x-api-key" })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(daily_response)

      expect(flash[:alert]).to eq("Your API key was rejected — check it in Settings.")
      expect(flash[:alert]).not_to include("x-api-key")
    end

    it "shows a try-again alert when the provider raises RateLimitError" do
      daily_response = create_submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return("code_review" => { ok: false, error_code: "rate_limit", message: "rate limited" })
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
      fake = instance_double(ClaudeService, review_sections: {
        "code_review" => { ok: true, review: { "rating" => "developing", "correct" => "ok",
                           "missed" => "", "better_questions" => "", "next_step" => "", "improved_code" => "" } }
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
      allow(fake_service).to receive(:review_sections).and_return("code_review" => { ok: true, review: { "rating" => "solid" } })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(resp)

      expect(response).to redirect_to(root_path(anchor: "ai-review"))
      expect(resp.reload.ai_review).to eq("code_review" => { "rating" => "solid" })
      expect(resp.reviewing_since).to be_nil
    end

    it "clears the claim on success so a stray marker never lingers" do
      resp = submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return("code_review" => { ok: true, review: { "rating" => "solid" } })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(resp)

      expect(resp.reload.reviewing_since).to be_nil
    end

    it "clears the claim when the provider raises, so an immediate retry can proceed" do
      resp = submitted_response
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return("code_review" => { ok: false, error_code: "other", message: "boom" })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(resp)

      expect(resp.reload.reviewing_since).to be_nil
    end
  end

  # A review closes the day to regeneration, and every path that clears this
  # message runs through regeneration — so a message left standing would tell
  # the user to retry something the reviewed-set guard now refuses.
  describe "POST /responses/:id/review and a stale generation failure" do
    def submitted_response
      exercise = create_exercise("code_review" => { "question" => "q", "snippet" => "s" })
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
    end

    def stub_review(result)
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:review_sections).and_return("code_review" => result)
      allow(AiService).to receive(:for).with(user).and_return(fake_service)
    end

    it "clears today's regeneration failure once a section is reviewed" do
      resp = submitted_response
      user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
      stub_review({ ok: true, review: { "rating" => "solid" } })

      post review_response_path(resp)

      expect(user.reload.last_generation_error).to be_nil
      expect(user.last_generation_error_date).to be_nil
    end

    it "leaves it standing when no section could be reviewed" do
      resp = submitted_response
      user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
      stub_review({ ok: false, error_code: "other", message: "provider down" })

      post review_response_path(resp)

      expect(user.reload.last_generation_error).to eq("boom")
    end

    it "leaves an earlier day's failure alone" do
      resp = submitted_response
      user.update!(last_generation_error_date: Date.current - 1, last_generation_error: "yesterday")
      stub_review({ ok: true, review: { "rating" => "solid" } })

      post review_response_path(resp)

      expect(user.reload.last_generation_error).to eq("yesterday")
    end
  end

  describe "POST /responses/:id/review partial success and retry" do
    def submitted_response
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current,
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s" },
          "pattern"     => { "title" => "t", "question" => "q" },
          "challenge"   => { "question" => "q" }
        }
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20, "pattern" => "a" * 20, "challenge" => "a" * 20 },
                            submitted_at: Time.current)
    end

    it "saves succeeded sections and records the failure reason for the rest, redirecting to the dashboard" do
      resp = submitted_response
      fake_service = instance_double(ClaudeService, review_sections: {
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "developing" } },
        "challenge"   => { ok: false, error_code: "rate_limit", message: "rate limited" }
      })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(resp)

      expect(response).to redirect_to(root_path(anchor: "ai-review"))
      expect(flash[:notice]).to eq("2 of 3 sections reviewed — 1 couldn't be reviewed, try again.")
      resp.reload
      expect(resp.ai_review.keys).to match_array(%w[code_review pattern])
      expect(resp.review_errors).to eq("challenge" => { "code" => "rate_limit", "message" => "rate limited" })
      expect(resp).not_to be_fully_reviewed
      expect(resp).to be_reviewed
    end

    it "only re-requests the still-missing section on retry, and clears its error once it succeeds" do
      resp = submitted_response
      resp.update!(
        ai_review: { "code_review" => { "rating" => "solid" }, "pattern" => { "rating" => "developing" } },
        review_errors: { "challenge" => { "code" => "rate_limit", "message" => "rate limited" } }
      )
      fake_service = instance_double(ClaudeService)
      allow(AiService).to receive(:for).with(user).and_return(fake_service)
      expect(fake_service).to receive(:review_sections)
        .with(user, resp.daily_exercise, resp, sections: %w[challenge])
        .and_return("challenge" => { ok: true, review: { "rating" => "strong" } })

      post review_response_path(resp)

      expect(response).to redirect_to(root_path(anchor: "ai-review"))
      expect(flash[:notice]).to eq("Review ready!")
      resp.reload
      expect(resp).to be_fully_reviewed
      expect(resp.review_errors).to eq({})
    end

    it "does not re-decrement a paused concept's cooldown on a retry that completes the review" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current,
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
          "pattern"     => { "title" => "t", "question" => "q" },
          "challenge"   => { "question" => "q" }
        }
      )
      resp = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "a" * 20, "pattern" => "a" * 20, "challenge" => "a" * 20 },
        submitted_at: Time.current, concept_tags: { "code_review" => "n_plus_one" }
      )
      paused = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)

      fake_service = instance_double(ClaudeService, review_sections: {
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "solid" } },
        "challenge"   => { ok: false, error_code: "other", message: "boom" }
      })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)
      post review_response_path(resp)
      expect(paused.reload.cooldown_remaining).to eq(1)

      retry_service = instance_double(ClaudeService, review_sections: {
        "challenge" => { ok: true, review: { "rating" => "solid" } }
      })
      allow(AiService).to receive(:for).with(user).and_return(retry_service)
      post review_response_path(resp)

      expect(paused.reload.cooldown_remaining).to eq(1)
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

    it "does not enqueue for a section the exercise holds but never presented" do
      create_exercise(
        "code_review"  => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"      => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "architecture" => { "title" => "t", "question" => "q", "concept" => "service_boundaries" },
        "challenge"    => { "title" => "t", "question" => "q", "concept" => "service_objects" }
      )

      expect {
        post responses_path,
          params: { response: { answers: { code_review: "a" * 20 }, submit: "1" } }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.not_to have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "service_objects", language: "ruby_rails", user_id: user.id)
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

    it "enqueues the security_review concept under the exercise's own language bucket, not a separate one" do
      create_exercise(
        "code_review"     => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"         => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
        "security_review" => { "title" => "t", "question" => "q", "concept" => "sql_injection_prevention" }
      )

      expect {
        post responses_path,
          params: { response: { answers: { security_review: "a" * 20 }, submit: "1" } }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.to have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "sql_injection_prevention", language: "ruby_rails", user_id: user.id)
        .exactly(:once)
        .and have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
        .exactly(:once)
        .and have_enqueued_job(GenerateConceptReferenceJob)
        .with(concept: "memoization", language: "ruby_rails", user_id: user.id)
        .exactly(:once)
    end
  end

  describe "POST /responses next-step targets on final submit" do
    it "returns the review URL on submit, so the dashboard can chain straight into it" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" })

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 }, submit: "1" } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(JSON.parse(response.body)["review_url"]).to eq(review_response_path(DailyResponse.last))
    end

    it "does not include a review URL on a non-submitting auto-save" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" })

      post responses_path,
        params: { response: { answers: { code_review: "a" * 20 } } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(JSON.parse(response.body)).not_to have_key("review_url")
    end

    it "redirects a native (no-JS) final submit back to the dashboard" do
      create_exercise("code_review" => { "question" => "q", "snippet" => "s" })

      post responses_path, params: { response: { answers: { code_review: "a" * 20 }, submit: "1" } }

      expect(response).to redirect_to(root_path)
    end
  end

  describe "PATCH /responses/:id/self_explanation" do
    let(:user) { create_user_with_key }

    def reviewed_response_for(owner)
      exercise = DailyExercise.create!(
        user: owner, date: Date.current - 5, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
      )
      DailyResponse.create!(
        user: owner, daily_exercise: exercise, date: Date.current - 5,
        answers: { "code_review" => "an answer with substance" },
        submitted_at: Time.current,
        ai_review: { "code_review" => { "rating" => "solid" } }
      )
    end

    it "saves and then updates an explanation for a valid section" do
      r = reviewed_response_for(user)
      login_as(user)

      patch self_explanation_response_path(r), params: { section: "code_review", text: "Because it batches the query" }
      expect(response).to have_http_status(:ok)
      expect(r.reload.self_explanations["code_review"]).to eq("Because it batches the query")

      patch self_explanation_response_path(r), params: { section: "code_review", text: "Revised reasoning" }
      expect(r.reload.self_explanations["code_review"]).to eq("Revised reasoning")
    end

    it "404s for another user's response" do
      other = create_user_with_key(email: "other@example.com", name: "Other")
      r = reviewed_response_for(other)
      login_as(user)

      patch self_explanation_response_path(r), params: { section: "code_review", text: "x" }
      expect(response).to have_http_status(:not_found)
      expect(r.reload.self_explanations).to eq({})
    end

    # Guards against a regression where require_reviewed_section! runs before
    # set_response: if the before_action order were ever swapped, this would
    # 422 ("no review yet") instead of 404, leaking that the row exists at all.
    # reviewed_response_for(other) would mask this — its ai_review is already
    # present, so both orderings would happen to 404/422 the same way. Only an
    # *unreviewed* other-user row can tell the two before_actions apart.
    it "404s for another user's unreviewed response, not 422" do
      other = create_user_with_key(email: "other@example.com", name: "Other")
      r = reviewed_response_for(other)
      r.update!(ai_review: nil)
      login_as(user)

      patch self_explanation_response_path(r), params: { section: "code_review", text: "x" }
      expect(response).to have_http_status(:not_found)
      expect(r.reload.self_explanations).to eq({})
    end

    it "rejects an unreviewed response" do
      r = reviewed_response_for(user)
      r.update!(ai_review: nil)
      login_as(user)

      patch self_explanation_response_path(r), params: { section: "code_review", text: "x" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(r.reload.self_explanations).to eq({})
    end

    it "rejects a section absent from the exercise's problem_set" do
      r = reviewed_response_for(user)
      login_as(user)

      patch self_explanation_response_path(r), params: { section: "architecture", text: "x" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(r.reload.self_explanations).to eq({})
    end

    it "uses the same {status, error} shape as the other review endpoints on a save failure" do
      r = reviewed_response_for(user)
      allow_any_instance_of(DailyResponse).to receive(:save).and_return(false)
      allow_any_instance_of(DailyResponse).to receive_message_chain(:errors, :full_messages).and_return([ "Answers is invalid" ])
      login_as(user)

      patch self_explanation_response_path(r), params: { section: "code_review", text: "x" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)).to eq("status" => "error", "error" => "Answers is invalid")
    end

    it "doesn't drop another section's explanation written concurrently by a second tab" do
      r = reviewed_response_for(user)
      # Simulates a second tab's request for a different section committing in
      # the gap between this request loading @response (in set_response) and
      # this request taking the row lock. Without with_lock's reload, the merge
      # would still be operating on the pre-concurrent-write in-memory hash and
      # would overwrite "pattern" on save.
      allow_any_instance_of(DailyResponse).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        DailyResponse.where(id: r.id)
          .update_all(%(self_explanations = self_explanations || '{"pattern":"concurrent"}'::jsonb))
        original.call(*args, &block)
      end
      login_as(user)

      patch self_explanation_response_path(r), params: { section: "code_review", text: "Because it batches the query" }

      expect(response).to have_http_status(:ok)
      expect(r.reload.self_explanations).to eq(
        "code_review" => "Because it batches the query",
        "pattern" => "concurrent"
      )
    end
  end

  describe "POST /responses/:id/explain_differently" do
    let(:user) { create_user_with_key }

    def reviewed_response_for(owner)
      exercise = DailyExercise.create!(
        user: owner, date: Date.current - 5, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
      )
      DailyResponse.create!(
        user: owner, daily_exercise: exercise, date: Date.current - 5,
        answers: { "code_review" => "an answer with substance" },
        submitted_at: Time.current,
        ai_review: { "code_review" => { "rating" => "solid", "missed" => [ "the index" ] } }
      )
    end

    def stub_alternate(text = "A different framing")
      fake = instance_double(ClaudeService)
      allow(AiService).to receive(:for).and_return(fake)
      allow(fake).to receive(:explain_differently).and_return(text)
      fake
    end

    it "appends an alternate and persists it" do
      r = reviewed_response_for(user)
      stub_alternate("First alternate")
      login_as(user)

      post explain_differently_response_path(r), params: { section: "code_review" }
      expect(response).to have_http_status(:ok)
      expect(r.reload.review_alternates["code_review"]).to eq([ "First alternate" ])
    end

    it "appends rather than replacing on a second call" do
      r = reviewed_response_for(user)
      stub_alternate("Second alternate")
      r.update!(review_alternates: { "code_review" => [ "First alternate" ] })
      login_as(user)

      post explain_differently_response_path(r), params: { section: "code_review" }
      expect(r.reload.review_alternates["code_review"]).to eq([ "First alternate", "Second alternate" ])
    end

    it "returns 422 at the cap and does not call the provider" do
      r = reviewed_response_for(user)
      r.update!(review_alternates: { "code_review" => [ "one", "two" ] })
      fake = stub_alternate
      login_as(user)

      post explain_differently_response_path(r), params: { section: "code_review" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(fake).not_to have_received(:explain_differently)
      expect(r.reload.review_alternates["code_review"]).to eq([ "one", "two" ])
      # Same error-body shape as follow_ups' cap and every other section error —
      # {"status", "error"} — not a hand-rolled one-off render.
      expect(JSON.parse(response.body)).to eq("status" => "error",
        "error" => "You've already asked for 2 alternate explanations here.")
    end

    it "404s for another user's response" do
      other = create_user_with_key(email: "other@example.com", name: "Other")
      r = reviewed_response_for(other)
      login_as(user)

      post explain_differently_response_path(r), params: { section: "code_review" }
      expect(response).to have_http_status(:not_found)
    end

    it "rejects a section absent from the exercise's problem_set" do
      r = reviewed_response_for(user)
      login_as(user)

      post explain_differently_response_path(r), params: { section: "challenge" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "leaves the stored array untouched when the provider fails" do
      r = reviewed_response_for(user)
      fake = instance_double(ClaudeService)
      allow(AiService).to receive(:for).and_return(fake)
      allow(fake).to receive(:explain_differently).and_raise(AiService::RateLimitError, "slow down")
      login_as(user)

      post explain_differently_response_path(r), params: { section: "code_review" }
      expect(response).to have_http_status(:service_unavailable)
      expect(r.reload.review_alternates).to eq({})
    end

    it "backs off without writing when another request fills the cap while this one waits on the provider" do
      r = reviewed_response_for(user)
      r.update!(review_alternates: { "code_review" => [ "one" ] })
      fake = instance_double(ClaudeService)
      allow(AiService).to receive(:for).and_return(fake)
      # The size-then-append cap check is race-able: the initial size (1, still
      # under the cap of 2) is read before this slow provider call. Simulate a
      # concurrent second request appending its own alternate while this one is
      # still waiting — the re-check inside with_lock must catch that the cap
      # was reached in the meantime, rather than overwriting it with a stale array.
      allow(fake).to receive(:explain_differently) do
        r.update!(review_alternates: { "code_review" => [ "one", "concurrent" ] })
        "A different framing"
      end
      login_as(user)

      post explain_differently_response_path(r), params: { section: "code_review" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(r.reload.review_alternates["code_review"]).to eq([ "one", "concurrent" ])
    end
  end

  describe "POST /responses/:id/follow_ups" do
    let(:user) { create_user_with_key }

    def reviewed_response_for(owner)
      exercise = DailyExercise.create!(
        user: owner, date: Date.current - 5, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
      )
      DailyResponse.create!(
        user: owner, daily_exercise: exercise, date: Date.current - 5,
        answers: { "code_review" => "an answer with substance" },
        submitted_at: Time.current,
        ai_review: { "code_review" => { "rating" => "solid" } }
      )
    end

    def stub_answer(text = "Because the query runs per row.")
      fake = instance_double(ClaudeService)
      allow(AiService).to receive(:for).and_return(fake)
      allow(fake).to receive(:answer_follow_up).and_return(text)
      fake
    end

    it "creates the user turn and the assistant turn, in order" do
      r = reviewed_response_for(user)
      stub_answer
      login_as(user)

      post follow_ups_response_path(r), params: { section: "code_review", question: "Why is that slow?" }
      expect(response).to have_http_status(:ok)

      turns = r.reload.review_follow_ups.for_section("code_review")
      expect(turns.map(&:role)).to eq(%w[user assistant])
      expect(turns.first.content).to eq("Why is that slow?")
      expect(turns.last.content).to eq("Because the query runs per row.")
    end

    it "reports remaining from the count taken inside the lock, not the pre-provider-call count" do
      r = reviewed_response_for(user)
      # A concurrent request lands between the advisory pre-check and the lock,
      # so the in-lock count (2) is one higher than the count read before the
      # provider call (1). remaining must reflect the fresher number.
      ReviewFollowUp.create!(daily_response: r, section: "code_review", role: :user, content: "already asked")
      fake = instance_double(ClaudeService)
      allow(AiService).to receive(:for).and_return(fake)
      allow(fake).to receive(:answer_follow_up) do
        ReviewFollowUp.create!(daily_response: r, section: "code_review", role: :user, content: "snuck in")
        "An answer"
      end
      login_as(user)

      post follow_ups_response_path(r), params: { section: "code_review", question: "Why is that slow?" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["remaining"]).to eq(0)
    end

    it "returns 422 at the cap and does not call the provider" do
      r = reviewed_response_for(user)
      3.times { |i| ReviewFollowUp.create!(daily_response: r, section: "code_review", role: :user, content: "q#{i}") }
      fake = stub_answer
      login_as(user)

      post follow_ups_response_path(r), params: { section: "code_review", question: "One more?" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(fake).not_to have_received(:answer_follow_up)
      expect(r.reload.review_follow_ups.where(role: :user).count).to eq(3)
    end

    it "rolls back the user turn when the provider fails" do
      r = reviewed_response_for(user)
      fake = instance_double(ClaudeService)
      allow(AiService).to receive(:for).and_return(fake)
      allow(fake).to receive(:answer_follow_up).and_raise(AiService::RateLimitError, "slow down")
      login_as(user)

      post follow_ups_response_path(r), params: { section: "code_review", question: "Why?" }
      expect(response).to have_http_status(:service_unavailable)
      expect(r.reload.review_follow_ups.count).to eq(0)
    end

    it "404s for another user's response" do
      other = create_user_with_key(email: "other@example.com", name: "Other")
      r = reviewed_response_for(other)
      login_as(user)

      post follow_ups_response_path(r), params: { section: "code_review", question: "Why?" }
      expect(response).to have_http_status(:not_found)
    end

    it "rejects a blank question" do
      r = reviewed_response_for(user)
      stub_answer
      login_as(user)

      post follow_ups_response_path(r), params: { section: "code_review", question: "   " }
      expect(response).to have_http_status(:unprocessable_content)
      expect(r.reload.review_follow_ups.count).to eq(0)
    end

    it "backs off without writing when another request fills the cap while this one waits on the provider" do
      r = reviewed_response_for(user)
      2.times { |i| ReviewFollowUp.create!(daily_response: r, section: "code_review", role: :user, content: "q#{i}") }
      fake = instance_double(ClaudeService)
      allow(AiService).to receive(:for).and_return(fake)
      # The count-then-create cap check is race-able: the initial count (2, still
      # under the cap of 3) is read before this slow provider call. Simulate a
      # concurrent second request completing its own turn pair while this one is
      # still waiting — the re-check inside with_lock must catch that the cap
      # was reached in the meantime, rather than blindly writing a 4th user turn.
      allow(fake).to receive(:answer_follow_up) do
        ReviewFollowUp.create!(daily_response: r, section: "code_review", role: :user, content: "concurrent")
        "An answer"
      end
      login_as(user)

      post follow_ups_response_path(r), params: { section: "code_review", question: "One more?" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(r.reload.review_follow_ups.where(role: :user).count).to eq(3)
    end
  end

  describe "security_review end-to-end" do
    def create_security_review_exercise
      DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review"      => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
          "pattern"          => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
          "security_review"  => { "title" => "Injection risk", "question" => "What's exploitable here?",
                                  "snippet" => "User.where(\"name = '\#{params[:name]}'\")",
                                  "concept" => "sql_injection_prevention" }
        }
      )
    end

    it "accepts a submitted answer, rating, and completes review through history" do
      exercise = create_security_review_exercise

      post responses_path,
        params: { response: {
          answers: { code_review: "a" * 20, pattern: "b" * 20, security_review: "c" * 20 },
          section_ratings: { code_review: "right_level", pattern: "right_level", security_review: "right_level" },
          submit: "1"
        } }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      resp = DailyResponse.last
      expect(resp.submitted?).to be true
      expect(resp.answers["security_review"]).to eq("c" * 20)
      expect(resp.concept_tags["security_review"]).to eq("sql_injection_prevention")

      fake_review = {
        "code_review"     => { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "" },
        "pattern"         => { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "" },
        "security_review" => { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "fixed = User.where(name: params[:name])" }
      }
      fake_service = instance_double(ClaudeService, review_sections: fake_review.transform_values { |r| { ok: true, review: r } })
      allow(AiService).to receive(:for).with(user).and_return(fake_service)

      post review_response_path(resp)
      expect(response).to redirect_to(root_path(anchor: "ai-review"))
      expect(resp.reload.ai_review["security_review"]["rating"]).to eq("solid")

      get history_path
      # "Injection risk" is security_review["title"] — the only place in this
      # page that string can come from is the section's own render, via
      # responses/_section's label. (A weaker assertion on "Security review" would also pass off
      # history/index.html.erb's independent section.humanize pill, which
      # renders for any rated section regardless of whether the answer
      # partial rendered anything.)
      expect(response.body).to include("Injection risk")
    end
  end

  describe "DELETE /responses/:id/start_over" do
    def create_response_for(owner, submitted: false, reviewed: false, date: Date.current, reviewing_since: nil)
      exercise = DailyExercise.create!(
        user: owner, date: date, generated_at: Time.current,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
      )
      DailyResponse.create!(
        user: owner, daily_exercise: exercise, date: date,
        answers: { "code_review" => "a" * 20 },
        submitted_at: submitted ? Time.current : nil,
        reviewing_since: reviewing_since,
        ai_review: reviewed ? { "code_review" => { "rating" => "solid" } } : nil
      )
    end

    it "requires login" do
      daily_response = create_response_for(user)
      delete logout_path

      delete start_over_response_path(daily_response)
      expect(response).to redirect_to(login_path)
    end

    it "404s for another user's response" do
      other = create_user_with_key(email: "other@example.com", name: "Other")
      daily_response = create_response_for(other)

      delete start_over_response_path(daily_response)
      expect(response).to have_http_status(:not_found)
    end

    it "destroys an unsubmitted draft and redirects to the dashboard" do
      daily_response = create_response_for(user, submitted: false)

      delete start_over_response_path(daily_response)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq("Today's answers have been cleared — start fresh whenever you're ready.")
      expect(DailyResponse.exists?(daily_response.id)).to be false
    end

    it "destroys a submitted-but-unreviewed response" do
      daily_response = create_response_for(user, submitted: true)

      delete start_over_response_path(daily_response)

      expect(response).to redirect_to(root_path)
      expect(DailyResponse.exists?(daily_response.id)).to be false
    end

    it "refuses to destroy a response with at least one reviewed section, without deleting it" do
      daily_response = create_response_for(user, submitted: true, reviewed: true)

      delete start_over_response_path(daily_response)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("This set has already been reviewed — nothing to start over.")
      expect(DailyResponse.exists?(daily_response.id)).to be true
    end

    it "refuses to destroy an earlier day's unreviewed response" do
      daily_response = create_response_for(user, submitted: true, date: Date.current - 1)

      delete start_over_response_path(daily_response)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("You can only start over on today's set.")
      expect(DailyResponse.exists?(daily_response.id)).to be true
    end

    it "resolves today in the user's timezone" do
      user.update!(time_zone: "Asia/Tokyo")
      travel_to Time.utc(2026, 3, 10, 23, 0) do
        daily_response = create_response_for(user, submitted: true, date: Date.new(2026, 3, 11))

        delete start_over_response_path(daily_response)

        expect(response).to redirect_to(root_path)
        expect(DailyResponse.exists?(daily_response.id)).to be false
      end
    end

    it "refuses while a review is actively being generated" do
      daily_response = create_response_for(user, submitted: true, reviewing_since: 10.seconds.ago)

      delete start_over_response_path(daily_response)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("A review is being generated for this — try again in a moment.")
      expect(DailyResponse.exists?(daily_response.id)).to be true
    end

    it "destroys when an abandoned review claim has gone stale" do
      daily_response = create_response_for(
        user, submitted: true,
        reviewing_since: (DailyResponse::REVIEW_CLAIM_STALE_AFTER + 1.minute).ago
      )

      delete start_over_response_path(daily_response)

      expect(response).to redirect_to(root_path)
      expect(DailyResponse.exists?(daily_response.id)).to be false
    end
  end

  describe "dashboard unsubmitted render of a security_review exercise" do
    it "renders the security_review title, answer textarea, and rating row with the exact names the controller and JS agree on" do
      DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review"      => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
          "pattern"          => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
          "security_review"  => { "title" => "Injection risk", "question" => "What's exploitable here?",
                                  "snippet" => "User.where(\"name = '\#{params[:name]}'\")",
                                  "concept" => "sql_injection_prevention" }
        }
      )

      get root_path

      expect(response.body).to include("Injection risk")
      expect(response.body).to include("exploitable here")
      expect(response.body).to include('name="response[answers][security_review]"')
      expect(response.body).to include('data-rating-for="security_review"')
    end
  end

  describe "answer scaffolds" do
    let(:scaffold) { [ "Which cache, and why:", "How you'd invalidate it:" ] }
    let(:template) { ExerciseSection::Architecture.scaffold_template("answer_scaffold" => scaffold) }

    # The dashboard form renders all three sections, so these need a full set
    # rather than the single section the POST paths above can get away with.
    def full_set(third = "architecture", scaffold: nil)
      third_data = { "title" => "t", "question" => "q" }
      third_data["answer_scaffold"] = scaffold if scaffold
      {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern"     => { "title" => "t", "why" => "w", "question" => "q" },
        third         => third_data
      }
    end

    def post_answers(exercise, answers)
      post responses_path, params: { response: { answers: answers } }, as: :json
      DailyResponse.find_by(user: user, daily_exercise: exercise)
    end

    def textarea_body(field)
      response.body[/<textarea[^>]*data-field="#{field}"[^>]*>(.*?)<\/textarea>/m, 1]
    end

    describe "POST /responses normalization" do
      # Rating a section triggers an autosave that posts every textarea's raw
      # value, so an untouched scaffold reaches the server whether the user
      # typed or not. It must not be stored as if it were an answer.
      it "stores a blank answer when only the scaffold comes back" do
        exercise = create_exercise(full_set("architecture", scaffold: scaffold))
        saved = post_answers(exercise, "architecture" => template)

        expect(saved.answers["architecture"]).to eq("")
        expect(saved.answered_sections).to be_empty
      end

      it "stores the user's text with its labels intact once they type" do
        exercise = create_exercise(full_set("architecture", scaffold: scaffold))
        filled = template + "Redis, because reads dominate"
        saved = post_answers(exercise, "architecture" => filled)

        expect(saved.answers["architecture"]).to eq(filled)
        expect(saved.answered_sections).to eq([ "architecture" ])
      end

      it "does not blank an unscaffolded section that happens to be short" do
        exercise = create_exercise(full_set)
        saved = post_answers(exercise, "code_review" => "n+1")

        expect(saved.answers["code_review"]).to eq("n+1")
      end
    end

    describe "GET / pre-fill" do
      it "pre-fills a fresh textarea with the scaffold written for this problem" do
        create_exercise(full_set("architecture", scaffold: scaffold))

        get root_path

        # Asserted on the textarea's contents, not the page: the labels also
        # appear in data-scaffold-labels, so a page-wide match would pass even
        # if the pre-fill never happened.
        expect(textarea_body("architecture")).to eq(ERB::Util.html_escape(template))

        labels_attr = response.body[/<textarea[^>]*data-field="architecture"[^>]*>/][/data-scaffold-labels="([^"]*)"/, 1]
        expect(CGI.unescapeHTML(labels_attr)).to eq(scaffold.to_json)
      end

      it "falls back to the kind's default labels when the problem carries no scaffold" do
        create_exercise(full_set)

        get root_path

        expect(textarea_body("architecture"))
          .to eq(ERB::Util.html_escape(ExerciseSection::Architecture.scaffold_template(nil)))
        expect(textarea_body("pattern"))
          .to eq(ERB::Util.html_escape(ExerciseSection::Pattern.scaffold_template(nil)))
      end

      it "shows a previously saved answer instead of the scaffold" do
        exercise = create_exercise(full_set)
        DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                              answers: { "pattern" => "My own words, written before scaffolds existed" })

        get root_path

        expect(textarea_body("pattern")).to eq("My own words, written before scaffolds existed")
      end

      it "does not pre-fill an unscaffolded section" do
        create_exercise(full_set("challenge"))

        get root_path

        expect(textarea_body("challenge")).to eq("")
        expect(textarea_body("code_review")).to eq("")
      end
    end
  end

  describe "submit-gating and review across a four-section exercise" do
    def four_section_problem_set
      {
        "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "SO", "why" => "Because", "question" => "When?", "concept" => "service_objects" },
        "challenge"   => { "title" => "Build", "question" => "Implement X", "starter_code" => "", "concept" => "memoization" },
        "plan_review" => {
          "title" => "Cache plan", "question" => "What's wrong?",
          "plan_excerpt" => "Cache for 300 seconds.", "concept" => "unjustified_constant"
        }
      }
    end

    it "requires a rating on all four sections, including the fourth slot, before submit succeeds as a full submission" do
      exercise = create_exercise(four_section_problem_set)

      post responses_path, params: {
        response: {
          answers: exercise.problem_set.keys.index_with { "a substantive answer here" },
          section_ratings: exercise.problem_set.keys.index_with { "right_level" },
          submit: "1"
        }
      }, as: :json

      expect(response).to have_http_status(:ok)
      saved = DailyResponse.find_by(user: user, daily_exercise: exercise)
      expect(saved).to be_submitted
      expect(saved.answered_sections).to include("plan_review")
      expect(saved.completeness).to eq(100)
    end

    it "copies the fourth section's concept tag onto the response, same as any other section" do
      exercise = create_exercise(four_section_problem_set)

      post responses_path, params: { response: { answers: { "plan_review" => "a" * 20 } } }, as: :json

      saved = DailyResponse.find_by(user: user, daily_exercise: exercise)
      expect(saved.concept_tags["plan_review"]).to eq("unjustified_constant")
    end
  end
end
