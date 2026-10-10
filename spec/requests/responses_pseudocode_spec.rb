require "rails_helper"

RSpec.describe "Pseudocode rounds", type: :request do
  let(:user) { create_fake_provider_user }

  # FakeService's full set lets plan_review win the fourth slot, so pseudocode_to_code would never be active.
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

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/already/i)
    end

    it "refuses a second critique even when the first found no gaps, since the cap keys on critiqued_at" do
      allow_any_instance_of(FakeService).to receive(:critique_pseudocode)
        .and_return({ gaps_found: false, gaps: [] })

      critique
      expect(response).to have_http_status(:ok)
      expect(round["gaps_found"]).to be(false)

      critique
      expect(response).to have_http_status(:unprocessable_content)
    end

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

    it "ignores a section parameter and only ever touches its own kind" do
      critique(section: "challenge")

      expect(response).to have_http_status(:ok)
      expect(user.daily_responses.find_by(date: Date.current).pseudocode_rounds.keys)
        .to eq([ "pseudocode_to_code" ])
    end

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

    it "lets a stale claim be reclaimed after the same window #review uses" do
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
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/already running/i)
    end

    it "reuses today's response when the autosave already created it" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "pseudocode_to_code" => "sort then walk" })

      critique

      expect(response).to have_http_status(:ok)
      expect(round["critiqued_at"]).to be_present
      expect(user.daily_responses.where(date: Date.current).count).to eq(1)
    end

    it "reuses today's response when it is created after the lookup" do
      # The controller uses the association proxy; a class-level stub never intercepts it.
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
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects blank and over-length pseudocode without calling the provider" do
      expect_any_instance_of(FakeService).not_to receive(:critique_pseudocode)

      critique(pseudocode: "   ")
      expect(response).to have_http_status(:unprocessable_content)

      critique(pseudocode: "x" * (ExerciseSection::PseudocodeToCode::MAX_PSEUDOCODE_LENGTH + 1))
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses once today's response has been submitted" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)

      critique
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s when there is no exercise for today" do
      exercise.destroy!

      critique
      expect(response).to have_http_status(:not_found)
    end
  end

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

      page = Nokogiri::HTML(response.body)
      expect(code_block_text(page.at_css(".pseudocode-code code.highlight"))).to eq("<script>alert(1)</script>")
      expect(response.body).to include("&lt;img src=x onerror=alert(1)&gt;")
      expect(response.body).not_to include("<script>alert(1)</script>")
    end
  end

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

    it "counts the grader's missed points, not the prose judge's merged ones" do
      response_row = submitted_response(
        rounds: { "gaps_found" => false, "critique" => [], "critiqued_at" => Time.current.iso8601,
                  "generated_code" => "def f; end", "translated_at" => Time.current.iso8601 },
        review: nil
      )

      lines = logged_pseudocode_lines do
        allow_any_instance_of(FakeService).to receive(:review_sections).and_return(
          "pseudocode_to_code" => { ok: true, review: { "rating" => "developing", "missed" => [ "a and b" ],
                                                        "correct" => [], "better_questions" => [],
                                                        "next_step" => "x", "improved_code" => "",
                                                        "graded_prose" => { "missed" => %w[a b c] } } }
        )
        post review_response_path(response_row)
      end

      expect(lines.find { |l| l.include?("phase=review") }).to include("missed=3", "disagreement=true")
    end
  end

  describe "translation at review time" do
    def submit_and_review(answer: "sort the ranges then walk them", rounds: {})
      row = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
        answers: { "pseudocode_to_code" => answer },
        pseudocode_rounds: rounds.present? ? { "pseudocode_to_code" => rounds } : {}
      )
      post review_response_path(row)
      row.reload
    end

    it "translates the submitted plan and stores it exactly as the round did" do
      row = submit_and_review

      round = row.pseudocode_round("pseudocode_to_code")
      expect(round["generated_code"]).to include("def merge_ranges")
      expect(round["translated_from"]).to eq("sort the ranges then walk them")
      expect(round["translated_at"]).to be_present
    end

    it "grades the section against the code it just generated" do
      prompts = []
      allow_any_instance_of(FakeService).to receive(:call).and_wrap_original do |original, **kwargs|
        prompts << [ kwargs[:system], kwargs[:prompt] ]
        original.call(**kwargs)
      end

      submit_and_review

      _system, grading_prompt = prompts.find { |system, _| system.to_s.include?("giving direct, specific feedback") }
      expect(grading_prompt).to be_present
      _system, day_context = prompts.find { |system, _| system.to_s.include?("def merge_ranges") }
      expect(day_context).to be_present
    end

    it "skips a section nobody answered rather than translating a blank plan" do
      expect_any_instance_of(FakeService).not_to receive(:translate_pseudocode)

      row = submit_and_review(answer: "")

      expect(row.pseudocode_round("pseudocode_to_code")["translated_at"]).to be_nil
    end

    it "leaves an existing translation alone, so a partial review's retry never pays for it again" do
      expect_any_instance_of(FakeService).not_to receive(:translate_pseudocode)

      row = submit_and_review(rounds: { "generated_code" => "def already; end",
                                        "translated_from" => "an earlier plan",
                                        "translated_at" => 1.hour.ago.iso8601 })

      expect(row.pseudocode_round("pseudocode_to_code")["generated_code"]).to eq("def already; end")
    end

    # #create bounds no answer length, so this skip is the only guard on the translation prompt.
    it "does not translate a plan past the length bound, but still reviews" do
      over_limit = "x" * (ExerciseSection::PseudocodeToCode::MAX_PSEUDOCODE_LENGTH + 1)
      expect_any_instance_of(FakeService).not_to receive(:translate_pseudocode)

      row = submit_and_review(answer: over_limit)

      expect(row.pseudocode_round("pseudocode_to_code")["translated_at"]).to be_nil
      expect(row.ai_review.keys).to include("pseudocode_to_code")
    end

    # Without the row lock, the translation's jsonb merge would overwrite a critique that landed mid-review.
    it "keeps a critique that lands mid-review instead of overwriting it" do
      row = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
        answers: { "pseudocode_to_code" => "sort the ranges then walk them" }
      )

      allow_any_instance_of(FakeService).to receive(:translate_pseudocode).and_wrap_original do |original, *args, **kwargs|
        DailyResponse.find(row.id).merge_pseudocode_round!(
          "pseudocode_to_code",
          "critique" => [ "No empty-input case." ], "gaps_found" => true,
          "critiqued_at" => Time.current.iso8601
        )
        original.call(*args, **kwargs)
      end

      post review_response_path(row)

      round = row.reload.pseudocode_round("pseudocode_to_code")
      expect(round["critiqued_at"]).to be_present
      expect(round["critique"]).to eq([ "No empty-input case." ])
      expect(round["generated_code"]).to include("def merge_ranges")
    end

    it "still reviews every section when the translation fails" do
      allow_any_instance_of(FakeService).to receive(:translate_pseudocode)
        .and_raise(AiService::Error, "provider down")

      row = submit_and_review

      expect(row.ai_review.keys).to include("pseudocode_to_code")
      expect(row.pseudocode_round("pseudocode_to_code")["translated_at"]).to be_nil
    end
  end
end
