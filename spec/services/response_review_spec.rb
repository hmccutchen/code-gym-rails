require "rails_helper"

RSpec.describe ResponseReview do
  include AuthHelpers

  let(:user) { create_user_with_key }
  let(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "concept" => "n_plus_one", "question" => "q", "snippet" => "s" },
                                         "pattern" => { "concept" => "memoization", "question" => "q" } })
  end
  let(:response) do
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                          answers: { "code_review" => "a" * 20, "pattern" => "b" * 20 },
                          section_ratings: { "code_review" => "right_level", "pattern" => "right_level" })
  end
  let(:reviewer) { instance_double(ClaudeService) }

  def review_result(rating) = { ok: true, review: { "rating" => rating } }
  def failed_result = { ok: false, failure: "outage", provider: "anthropic" }

  def review(subject_response = response)
    described_class.new(subject_response, user: user, reviewer: reviewer).call
  end

  it "reports a response that was never submitted, without calling the provider" do
    response.update!(submitted_at: nil)
    expect(reviewer).not_to receive(:review_sections)

    expect(review.status).to eq(:not_submitted)
  end

  it "reports a response with every section reviewed, without claiming it" do
    response.update!(ai_review: { "code_review" => { "rating" => "solid" }, "pattern" => { "rating" => "solid" } })
    expect(reviewer).not_to receive(:review_sections)

    expect(review.status).to eq(:already_reviewed)
    expect(response.reload.reviewing_since).to be_nil
  end

  it "backs off while another review holds a fresh claim" do
    response.update!(reviewing_since: Time.current)
    expect(reviewer).not_to receive(:review_sections)

    expect(review.status).to eq(:busy)
  end

  it "reviews only the sections still missing and stores every result" do
    response.update!(ai_review: { "code_review" => { "rating" => "solid" } })
    allow(reviewer).to receive(:review_sections).and_return("pattern" => review_result("strong"))

    outcome = review

    expect(reviewer).to have_received(:review_sections).with(user, exercise, response, sections: %w[pattern])
    expect(outcome.status).to eq(:ready)
    expect(response.reload.ai_review).to eq("code_review" => { "rating" => "solid" }, "pattern" => { "rating" => "strong" })
    expect(response.review_provider).to eq(user.provider)
    expect(response.reviewing_since).to be_nil
  end

  it "reports a partial review, stores the failures, and keeps the claim free for a retry" do
    allow(reviewer).to receive(:review_sections)
      .and_return("code_review" => review_result("solid"), "pattern" => failed_result)

    outcome = review

    expect(outcome.status).to eq(:partial)
    expect(outcome.successes.keys).to eq(%w[code_review])
    expect(outcome.failures.keys).to eq(%w[pattern])
    expect(outcome.missing).to eq(%w[code_review pattern])
    expect(response.reload.review_errors.dig("pattern", "kind")).to eq("outage")
    expect(response.reviewing_since).to be_nil
  end

  it "clears a section's stored failure once a retry reviews it" do
    response.update!(ai_review: { "code_review" => { "rating" => "solid" } },
                     review_errors: { "pattern" => { "kind" => "outage" } })
    allow(reviewer).to receive(:review_sections).and_return("pattern" => review_result("solid"))

    review

    expect(response.reload.review_errors).to eq({})
  end

  it "reports a review where every section failed, and writes no mastery" do
    allow(reviewer).to receive(:review_sections).and_return("code_review" => failed_result, "pattern" => failed_result)

    expect { expect(review.status).to eq(:failed) }.not_to change(ConceptMastery, :count)
  end

  it "records mastery for the reviewed sections, counting the session only on the first batch" do
    allow(reviewer).to receive(:review_sections)
      .and_return("code_review" => review_result("solid"), "pattern" => review_result("solid"))
    allow(ConceptMastery).to receive(:record_review!)

    review

    expect(ConceptMastery).to have_received(:record_review!)
      .with(response, sections: %w[code_review pattern], apply_session_countdown: true)
  end

  it "does not count the session again on a later batch" do
    response.update!(ai_review: { "code_review" => { "rating" => "solid" } })
    allow(reviewer).to receive(:review_sections).and_return("pattern" => review_result("solid"))
    allow(ConceptMastery).to receive(:record_review!)

    review

    expect(ConceptMastery).to have_received(:record_review!)
      .with(response, sections: %w[pattern], apply_session_countdown: false)
  end

  it "reads today in the user's zone, so a caller outside a request clears the right day's error" do
    travel_to Time.utc(2026, 10, 12, 20, 0) do
      user.update!(time_zone: "Auckland", last_generation_error: "Couldn't generate",
                   last_generation_error_date: Date.new(2026, 10, 13))
      allow(reviewer).to receive(:review_sections).and_return("code_review" => review_result("solid"),
                                                              "pattern" => review_result("solid"))

      Time.use_zone("UTC") { review }

      expect(user.reload.last_generation_error_date).to be_nil
    end
  end

  it "re-checks after taking the claim and stops when another review finished the day" do
    allow(response).to receive(:claim_reviewing!).and_wrap_original do |original|
      token = original.call
      DailyResponse.where(id: response.id).update_all(
        ai_review: { "code_review" => { "rating" => "solid" }, "pattern" => { "rating" => "solid" } })
      token
    end
    expect(reviewer).not_to receive(:review_sections)

    expect(review.status).to eq(:already_reviewed)
    expect(response.reload.reviewing_since).to be_nil
  end

  it "reports a provider error and releases the claim" do
    error = ProviderError.new("boom")
    allow(reviewer).to receive(:review_sections).and_raise(error)

    outcome = review

    expect(outcome.status).to eq(:provider_error)
    expect(outcome.error).to be(error)
    expect(response.reload.reviewing_since).to be_nil
  end

  it "builds the provider inside the call, so a refused credential is a provider error" do
    allow(AiService).to receive(:for).with(user).and_raise(ProviderError::TrialEndedError.new("ended"))

    outcome = described_class.new(response, user: user).call

    expect(outcome.status).to eq(:provider_error)
    expect(response.reload.reviewing_since).to be_nil
  end

  it "reports a setup error as a handled outcome and releases the claim" do
    error = SetupError.new("Unsupported generation language: \"cobol\"")
    allow(reviewer).to receive(:review_sections).and_raise(error)

    outcome = review

    expect(outcome.status).to eq(:provider_error)
    expect(outcome.error).to be(error)
    expect(response.reload.reviewing_since).to be_nil
  end

  it "reports a set cleared while the review ran" do
    allow(reviewer).to receive(:review_sections) do
      DailyResponse.where(id: response.id).delete_all
      { "code_review" => review_result("solid"), "pattern" => review_result("solid") }
    end

    expect(review.status).to eq(:set_cleared)
  end

  def create_exercise(problem_set, date = Date.current)
    DailyExercise.create!(user: user, date: date, problem_set: problem_set, generated_at: Time.current)
  end

  def stub_reviewer(results = nil, &block)
    fake_service = instance_double(ClaudeService)
    if block
      allow(fake_service).to receive(:review_sections, &block)
    else
      allow(fake_service).to receive(:review_sections).and_return(results)
    end
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    fake_service
  end

  def review_through_provider(subject_response)
    described_class.new(subject_response, user: user).call
  end

  describe "a three-section day" do
    def create_submitted_response(date: Date.current)
      exercise = create_exercise({ "code_review" => { "question" => "q", "snippet" => "s" },
                                   "pattern" => { "title" => "t", "question" => "q" },
                                   "challenge" => { "title" => "t", "question" => "q" } }, date)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: date,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
    end

    it "saves the ai_review from the user's configured provider" do
      daily_response = create_submitted_response
      stub_reviewer(
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "solid" } },
        "challenge"   => { ok: true, review: { "rating" => "solid" } }
      )

      outcome = review_through_provider(daily_response)

      expect(outcome.status).to eq(:ready)
      expect(daily_response.reload.ai_review.keys).to match_array(%w[code_review pattern challenge])
      expect(daily_response.review_provider).to eq("anthropic")
    end

    it "logs the AI rating paired with the user's self-rating for each reviewed section" do
      daily_response = create_submitted_response
      daily_response.update!(answers: daily_response.answers.merge("pattern" => "My approach:\n#{"b" * 20}", "challenge" => "c" * 20),
                             section_ratings: { "code_review" => "right_level", "pattern" => "too_hard" })
      stub_reviewer(
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "beginner" } },
        "challenge"   => { ok: true, review: { "rating" => "solid" } }
      )

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
      end

      review_through_provider(daily_response)

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
      exercise = create_exercise({ "code_review" => { "question" => "q", "snippet" => "s" } }, Date.current - 1)
      daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                             answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
      stub_reviewer("code_review" => { ok: true, review: { "rating" => "solid" } })

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
      end

      review_through_provider(daily_response)

      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))
      expect(payload["date"]).to eq(exercise.date.to_s)
      expect(payload["date"]).not_to eq(daily_response.date.to_s)
    end

    it "does not log when every section fails" do
      daily_response = create_submitted_response
      stub_reviewer(
        "code_review" => { ok: false, error_code: "rate_limit", message: "slow down" },
        "pattern"     => { ok: false, error_code: "rate_limit", message: "slow down" },
        "challenge"   => { ok: false, error_code: "rate_limit", message: "slow down" }
      )

      expect(Rails.logger).not_to receive(:info).with(/\[difficulty_diagnostics\]/)

      expect(review_through_provider(daily_response).status).to eq(:failed)
    end

    it "abandons the review without writing mastery state if the response is destroyed mid-flight" do
      daily_response = create_submitted_response
      stub_reviewer do
        DailyResponse.where(id: daily_response.id).delete_all
        {
          "code_review" => { ok: true, review: { "rating" => "solid" } },
          "pattern"     => { ok: true, review: { "rating" => "solid" } },
          "challenge"   => { ok: true, review: { "rating" => "solid" } }
        }
      end

      outcome = nil
      expect { outcome = review_through_provider(daily_response) }.not_to change(ConceptMastery, :count)

      expect(outcome.status).to eq(:set_cleared)
      expect(DailyResponse.exists?(daily_response.id)).to be false
    end

    it "stores the provider the section's call went to" do
      daily_response = create_submitted_response
      stub_reviewer("code_review" => { ok: false, error_code: "rate_limit", failure: "short_rate_limit", provider: "openai", retry_after: 30 })

      expect(review_through_provider(daily_response).status).to eq(:failed)

      expect(daily_response.reload.review_errors["code_review"]).to include("provider" => "openai", "retry_after" => 30)
    end

    it "keeps the time each section failed, not the time the review finished, which can be a day later" do
      daily_response = create_submitted_response
      failed_at = Time.utc(2026, 10, 7, 6, 59, 30)
      stub_reviewer do
        travel_to(Time.utc(2026, 10, 7, 7, 1))
        { "code_review" => { ok: false, error_code: "rate_limit", failure: "daily_limit", provider: "gemini",
                             quota_id: "GenerateRequestsPerDayPerProjectPerModel-FreeTier", failed_at: failed_at } }
      end

      expect(review_through_provider(daily_response).status).to eq(:failed)

      expect(daily_response.reload.review_errors["code_review"]["at"]).to eq(failed_at.iso8601)
    ensure
      travel_back
    end
  end

  describe "the mastery write" do
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
      review_through_provider(resp)

      expect(resp.reload.ai_review).to be_present
      expect(user.concept_masteries.find_by(concept: "n_plus_one", language: "ruby_rails")).to be_present
    end

    it "rolls back the review if the mastery write fails" do
      resp = submitted_response
      allow(ConceptMastery).to receive(:record_review!).and_raise(ActiveRecord::RecordInvalid.new(ConceptMastery.new))

      expect { review_through_provider(resp) }.to raise_error(ActiveRecord::RecordInvalid)

      expect(resp.reload.ai_review).to be_nil
      expect(resp.reviewing_since).to be_nil
    end
  end

  describe "the review claim" do
    def submitted_response(reviewing_since: nil)
      exercise = create_exercise("code_review" => { "question" => "q", "snippet" => "s" })
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
                            reviewing_since: reviewing_since)
    end

    it "reclaims the review after the in-flight marker goes stale" do
      resp = submitted_response(reviewing_since: (DailyResponse::REVIEW_CLAIM_STALE_AFTER + 1.minute).ago)
      stub_reviewer("code_review" => { ok: true, review: { "rating" => "solid" } })

      expect(review_through_provider(resp).status).to eq(:ready)

      expect(resp.reload.ai_review).to eq("code_review" => { "rating" => "solid" })
      expect(resp.reviewing_since).to be_nil
    end

    it "clears the claim when every section fails, so an immediate retry can proceed" do
      resp = submitted_response
      stub_reviewer("code_review" => { ok: false, error_code: "other", failure: "other" })

      expect(review_through_provider(resp).status).to eq(:failed)

      expect(resp.reload.reviewing_since).to be_nil
    end

    context "when another review takes the claim over during the provider call" do
      let(:takeover) { 1.second.from_now.floor(6) }

      def take_over(resp)
        DailyResponse.where(id: resp.id).update_all(reviewing_since: takeover)
      end

      it "leaves the new claim in place when this review finishes" do
        resp = submitted_response
        stub_reviewer do
          take_over(resp)
          { "code_review" => { ok: true, review: { "rating" => "solid" } } }
        end

        review_through_provider(resp)

        expect(resp.reload.reviewing_since).to eq(takeover)
      end

      it "discards its results rather than writing a review the new claim will write again" do
        resp = submitted_response
        stub_reviewer do
          take_over(resp)
          { "code_review" => { ok: true, review: { "rating" => "solid" } } }
        end
        allow(ConceptMastery).to receive(:record_review!)

        expect(review_through_provider(resp).status).to eq(:busy)

        expect(resp.reload.ai_review).to be_nil
        expect(ConceptMastery).not_to have_received(:record_review!)
      end

      it "leaves the new claim in place when the provider raises" do
        resp = submitted_response
        stub_reviewer do
          take_over(resp)
          raise ProviderError, "boom"
        end

        expect(review_through_provider(resp).status).to eq(:provider_error)

        expect(resp.reload.reviewing_since).to eq(takeover)
      end
    end
  end

  describe "a stale generation failure" do
    def submitted_response
      exercise = create_exercise("code_review" => { "question" => "q", "snippet" => "s" })
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
    end

    def stub_review(result)
      stub_reviewer("code_review" => result)
    end

    it "clears today's regeneration failure once a section is reviewed, since a review closes off regeneration" do
      resp = submitted_response
      user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
      stub_review({ ok: true, review: { "rating" => "solid" } })

      review_through_provider(resp)

      expect(user.reload.last_generation_error).to be_nil
      expect(user.last_generation_error_date).to be_nil
    end

    it "leaves it standing when no section could be reviewed" do
      resp = submitted_response
      user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
      stub_review({ ok: false, error_code: "other", failure: "outage" })

      review_through_provider(resp)

      expect(user.reload.last_generation_error).to eq("boom")
    end

    it "leaves an earlier day's failure alone" do
      resp = submitted_response
      user.update!(last_generation_error_date: Date.current - 1, last_generation_error: "yesterday")
      stub_review({ ok: true, review: { "rating" => "solid" } })

      review_through_provider(resp)

      expect(user.reload.last_generation_error).to eq("yesterday")
    end
  end

  describe "partial success and retry" do
    def submitted_response
      exercise = create_exercise(
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern"     => { "title" => "t", "question" => "q" },
        "challenge"   => { "question" => "q" }
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20, "pattern" => "a" * 20, "challenge" => "a" * 20 },
                            submitted_at: Time.current)
    end

    it "saves succeeded sections and records the failure reason for the rest" do
      resp = submitted_response
      stub_reviewer(
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "developing" } },
        "challenge"   => { ok: false, error_code: "rate_limit", failure: "short_rate_limit", retry_after: 20 }
      )

      expect(review_through_provider(resp).status).to eq(:partial)

      resp.reload
      expect(resp.ai_review.keys).to match_array(%w[code_review pattern])
      expect(resp.review_errors.keys).to eq([ "challenge" ])
      expect(resp.review_errors["challenge"]).to include("kind" => "short_rate_limit", "retry_after" => 20, "at" => be_present)
      expect(resp.review_errors["challenge"]).not_to have_key("message")
      expect(resp).not_to be_fully_reviewed
      expect(resp).to be_reviewed
    end

    it "only re-requests the still-missing section on retry, and clears its error once it succeeds" do
      resp = submitted_response
      resp.update!(
        ai_review: { "code_review" => { "rating" => "solid" }, "pattern" => { "rating" => "developing" } },
        review_errors: { "challenge" => { "kind" => "short_rate_limit", "at" => Time.current.iso8601 } }
      )
      fake_service = instance_double(ClaudeService)
      allow(AiService).to receive(:for).with(user).and_return(fake_service)
      expect(fake_service).to receive(:review_sections)
        .with(user, resp.daily_exercise, resp, sections: %w[challenge])
        .and_return("challenge" => { ok: true, review: { "rating" => "strong" } })

      expect(review_through_provider(resp).status).to eq(:ready)

      resp.reload
      expect(resp).to be_fully_reviewed
      expect(resp.review_errors).to eq({})
    end

    it "does not re-decrement a paused concept's cooldown on a retry that completes the review" do
      exercise = create_exercise(
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "t", "question" => "q" },
        "challenge"   => { "question" => "q" }
      )
      resp = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "a" * 20, "pattern" => "a" * 20, "challenge" => "a" * 20 },
        submitted_at: Time.current, concept_tags: { "code_review" => "n_plus_one" }
      )
      paused = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)

      stub_reviewer(
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "solid" } },
        "challenge"   => { ok: false, error_code: "other", failure: "other" }
      )
      review_through_provider(resp)
      expect(paused.reload.cooldown_remaining).to eq(1)

      stub_reviewer("challenge" => { ok: true, review: { "rating" => "solid" } })
      review_through_provider(resp)

      expect(paused.reload.cooldown_remaining).to eq(1)
    end
  end
end
