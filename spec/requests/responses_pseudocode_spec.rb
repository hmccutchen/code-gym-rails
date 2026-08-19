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
