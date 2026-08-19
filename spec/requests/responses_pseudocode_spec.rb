require "rails_helper"

# The two pseudocode_to_code rounds. Both are pre-submission provider calls the
# user pays for with their own key, so every guard here is about not spending a
# call the engineer didn't ask for — or spending one and not counting it.
RSpec.describe "Pseudocode rounds", type: :request do
  let(:user) { create_fake_provider_user }

  # Built by hand rather than from FakeService::EXERCISE_PROBLEM_SET, which
  # holds every kind at once: plan_review wins the fourth slot by precedence
  # there, so pseudocode_to_code would never be in active_section_keys and every
  # example below would 422 on the section guard.
  let!(:exercise) do
    DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review"        => FakeService::EXERCISE_PROBLEM_SET["code_review"],
        "pattern"            => FakeService::EXERCISE_PROBLEM_SET["pattern"],
        "challenge"          => FakeService::EXERCISE_PROBLEM_SET["challenge"],
        "pseudocode_to_code" => FakeService::EXERCISE_PROBLEM_SET["pseudocode_to_code"]
      }
    )
  end

  before { login_as(user) }

  def critique(params = {})
    post pseudocode_critique_responses_path,
         params: { section: "pseudocode_to_code", pseudocode: "sort the ranges then walk them" }.merge(params),
         as: :json
  end

  def translate(params = {})
    post pseudocode_translate_responses_path,
         params: { section: "pseudocode_to_code", pseudocode: "sort the ranges then walk them" }.merge(params),
         as: :json
  end

  def round
    user.daily_responses.find_by(date: Date.current)&.pseudocode_round("pseudocode_to_code") || {}
  end

  describe "POST pseudocode_critique" do
    it "stores the round and returns the typed flag with the points" do
      critique

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("ok")
      expect(body["gaps_found"]).to be(true)
      expect(body["gaps"]).to be_present

      expect(round["critiqued_at"]).to be_present
      expect(round["initial_pseudocode"]).to eq("sort the ranges then walk them")
    end

    it "refuses a second critique" do
      critique
      critique

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/already/i)
    end

    # The [].present? trap: a critique that found nothing is still spent. Keying
    # the cap on the critique list rather than on critiqued_at would leave the
    # most common good outcome uncapped.
    it "refuses a second critique even when the first found no gaps" do
      allow_any_instance_of(FakeService).to receive(:critique_pseudocode)
        .and_return({ gaps_found: false, gaps: [] })

      critique
      expect(response).to have_http_status(:ok)
      expect(round["gaps_found"]).to be(false)

      critique
      expect(response).to have_http_status(:unprocessable_entity)
    end

    # A provider hiccup must not silently spend the engineer's one critique.
    it "leaves the cap unconsumed when the provider response is malformed" do
      allow_any_instance_of(FakeService).to receive(:critique_pseudocode)
        .and_raise(AiService::InvalidResponseError, "claimed gaps but returned none usable")

      critique
      expect(response).to have_http_status(:service_unavailable)
      expect(round["critiqued_at"]).to be_nil

      allow_any_instance_of(FakeService).to receive(:critique_pseudocode).and_call_original
      critique
      expect(response).to have_http_status(:ok)
      expect(round["critiqued_at"]).to be_present
    end

    # The section is not a parameter any more — it comes from the registry — so a
    # crafted request cannot aim these endpoints at another kind at all.
    it "ignores a section parameter and only ever touches its own kind" do
      critique(section: "challenge")

      expect(response).to have_http_status(:ok)
      expect(user.daily_responses.find_by(date: Date.current).pseudocode_rounds.keys)
        .to eq([ "pseudocode_to_code" ])
    end

    # The cap has to bound the SPEND, not just the write: a check made only after
    # the call still bills both of two concurrent requests.
    it "claims the round before calling the provider, so a concurrent request never calls at all" do
      calls = 0
      allow_any_instance_of(FakeService).to receive(:critique_pseudocode) do
        calls += 1
        critique   # re-entrant: a second request arrives while this one is mid-call
        { gaps_found: true, gaps: [ "No empty-input case." ] }
      end

      critique

      expect(calls).to eq(1)
    end

    it "hands the round back when the provider fails, so a retry is immediate" do
      allow_any_instance_of(FakeService).to receive(:critique_pseudocode)
        .and_raise(AiService::Error, "provider down")
      critique
      expect(response).to have_http_status(:service_unavailable)
      expect(round["critique_claimed_at"]).to be_nil

      allow_any_instance_of(FakeService).to receive(:critique_pseudocode).and_call_original
      critique
      expect(response).to have_http_status(:ok)
    end

    # A crashed request must not lock the round forever — same window #review uses.
    it "lets a stale claim be reclaimed" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            pseudocode_rounds: { "pseudocode_to_code" => {
                              "critique_claimed_at" => (DailyResponse::REVIEW_CLAIM_STALE_AFTER.ago - 1.minute).iso8601
                            } })

      critique
      expect(response).to have_http_status(:ok)
    end

    it "refuses while a fresh claim is still in flight" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            pseudocode_rounds: { "pseudocode_to_code" => {
                              "critique_claimed_at" => Time.current.iso8601
                            } })

      critique
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/already running/i)
    end

    # The row is created before the provider call now (the claim needs something
    # to lock), so the autosave race moved into persisted_response_for. Either
    # ordering must end with exactly one row and no error: the uniqueness rule is
    # a validation AND an index, so the two orderings raise different classes.
    it "reuses today's response when the autosave already created it" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "pseudocode_to_code" => "sort then walk" })

      critique

      expect(response).to have_http_status(:ok)
      expect(round["critiqued_at"]).to be_present
      expect(user.daily_responses.where(date: Date.current).count).to eq(1)
    end

    it "reuses today's response when it is created after the lookup" do
      # The association proxy, not the class: the controller calls
      # current_user.daily_responses.find_or_create_by!, and a class-level stub
      # never intercepts it — which made an earlier version of this example pass
      # with the rescue deleted.
      allow_any_instance_of(ActiveRecord::Associations::CollectionProxy)
        .to receive(:find_or_create_by!).and_raise(ActiveRecord::RecordNotUnique, "dup")
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current)

      critique

      expect(response).to have_http_status(:ok)
      expect(user.daily_responses.where(date: Date.current).count).to eq(1)
    end

    it "rejects a section this exercise does not present" do
      allow_any_instance_of(DailyExercise).to receive(:active_section_keys).and_return(%w[code_review pattern])

      critique
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects blank and over-length pseudocode without calling the provider" do
      expect_any_instance_of(FakeService).not_to receive(:critique_pseudocode)

      critique(pseudocode: "   ")
      expect(response).to have_http_status(:unprocessable_entity)

      critique(pseudocode: "x" * (ResponsesController::MAX_PSEUDOCODE_LENGTH + 1))
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "refuses once today's response has been submitted" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)

      critique
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "404s when there is no exercise for today" do
      exercise.destroy!

      critique
      expect(response).to have_http_status(:not_found)
    end
  end

  # Generated code and critique points are provider output rendered into the
  # page. The client path uses textContent; this covers the server-rendered
  # half, which is what a reload shows.
  describe "rendering stored round output" do
    it "escapes generated code and critique text rather than emitting markup" do
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current,
        answers: { "pseudocode_to_code" => "sort then walk" },
        pseudocode_rounds: { "pseudocode_to_code" => {
          "gaps_found" => true, "critique" => [ "<img src=x onerror=alert(1)>" ],
          "critiqued_at" => Time.current.iso8601,
          "generated_code" => "<script>alert(1)</script>", "translated_at" => Time.current.iso8601
        } }
      )

      get root_path

      expect(response.body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(response.body).to include("&lt;img src=x onerror=alert(1)&gt;")
      expect(response.body).not_to include("<script>alert(1)</script>")
    end
  end

  # The measurement half of the design: a critique that found nothing followed
  # by a review that found plenty is the incoherence this feature is most
  # exposed to, so it is logged as a boolean rather than left to be
  # reconstructed from user reports later.
  describe "review diagnostics" do
    def submitted_response(rounds:, review:)
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
        answers: { "pseudocode_to_code" => "sort then walk the ranges" },
        pseudocode_rounds: { "pseudocode_to_code" => rounds }, ai_review: review
      )
    end

    def logged_pseudocode_lines
      lines = []
      allow(Rails.logger).to receive(:info) { |msg| lines << msg.to_s if msg.to_s.start_with?("[pseudocode]") }
      yield
      lines
    end

    it "flags the disagreement when a clean critique precedes a critical review" do
      response_row = submitted_response(
        rounds: { "gaps_found" => false, "critique" => [], "critiqued_at" => Time.current.iso8601,
                  "generated_code" => "def f; end", "translated_at" => Time.current.iso8601 },
        review: nil
      )

      lines = logged_pseudocode_lines do
        allow_any_instance_of(FakeService).to receive(:review_sections).and_return(
          "pseudocode_to_code" => { ok: true, review: { "rating" => "developing", "missed" => %w[a b c],
                                                        "correct" => [], "better_questions" => [],
                                                        "next_step" => "x", "improved_code" => "" } }
        )
        post review_response_path(response_row)
      end

      line = lines.find { |l| l.include?("phase=review") }
      expect(line).to include("user=#{user.id}", "critiqued=true", "gaps=0", "missed=3", "disagreement=true")
      expect(line).not_to include("sort then walk the ranges")
    end

    it "does not flag a disagreement when the critique itself raised points" do
      response_row = submitted_response(
        rounds: { "gaps_found" => true, "critique" => [ "No empty-input case." ],
                  "critiqued_at" => Time.current.iso8601,
                  "generated_code" => "def f; end", "translated_at" => Time.current.iso8601 },
        review: nil
      )

      lines = logged_pseudocode_lines do
        allow_any_instance_of(FakeService).to receive(:review_sections).and_return(
          "pseudocode_to_code" => { ok: true, review: { "rating" => "developing", "missed" => %w[a b],
                                                        "correct" => [], "better_questions" => [],
                                                        "next_step" => "x", "improved_code" => "" } }
        )
        post review_response_path(response_row)
      end

      line = lines.find { |l| l.include?("phase=review") }
      expect(line).to include("critiqued=true", "gaps=1", "missed=2", "disagreement=false")
    end
  end

  describe "POST pseudocode_translate" do
    it "stores the generated code and the plan that produced it" do
      translate

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["code"]).to include("def merge_ranges")

      expect(round["generated_code"]).to include("def merge_ranges")
      expect(round["translated_from"]).to eq("sort the ranges then walk them")
      expect(round["translated_at"]).to be_present
    end

    # translated_from is stored rather than assumed equal to answers[section]:
    # the engineer can keep editing the textarea after translating, and the
    # review has to know which text actually produced the code it is reading.
    it "records the plan it translated, not whatever the answer later becomes" do
      translate(pseudocode: "first version of the plan")

      expect(round["translated_from"]).to eq("first version of the plan")
    end

    it "refuses a second translation" do
      translate
      translate

      expect(response).to have_http_status(:unprocessable_entity)
    end

    # Round 2 is never gated on round 1 — there is no way to get stuck.
    it "works without a critique having been requested" do
      translate

      expect(response).to have_http_status(:ok)
      expect(round["critiqued_at"]).to be_nil
    end

    it "surfaces a provider failure as a 503 and stores nothing" do
      allow_any_instance_of(FakeService).to receive(:translate_pseudocode)
        .and_raise(AiService::Error, "provider down")

      translate
      expect(response).to have_http_status(:service_unavailable)
      expect(round["translated_at"]).to be_nil
    end
  end
end
