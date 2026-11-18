require "rails_helper"

RSpec.describe "The reply to an explanation", type: :request do
  let(:user) { create_user_with_key(email: "reply@example.com").tap { |owner| owner.update!(learner_notes_enabled: true) } }
  let(:calls) { [] }
  let(:replies) { [ ExplanationReply::Reply.new(sound: "You named the per-row query.", correction: "Preloading adds one query, not none.") ] }

  before do
    stub_env("LEARNER_NOTES" => "1")
    login_as(user)
    allow_any_instance_of(AiService).to receive(:explanation_reply) do |_service, _user, **values|
      calls << values
      outcome = replies.fetch(calls.size - 1) { replies.last }
      outcome.is_a?(Exception) ? raise(outcome) : outcome
    end
  end

  around { |example| travel_to(Time.utc(2026, 11, 18, 15)) { example.run } }

  let!(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => "n_plus_one" } })
  end
  let!(:response_row) do
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: { "code_review" => "ANSWER-TEXT" },
                          section_ratings: { "code_review" => "right_level" }, submitted_at: Time.current,
                          ai_review: { "code_review" => { "rating" => "solid", "correct" => "REVIEW-TEXT" } })
  end
  let!(:note) do
    LearnerNote.create!(user: user, daily_exercise: exercise, body: "NOTE-TEXT", explain_section: "code_review",
                        explain_concept: "n_plus_one", explain_phrasing: "explain.first", explanation: "One query per row.")
  end

  let(:shown) { { note_id: note.id, explanation_stamp: note.explanation_stamp } }

  def ask(identity = shown) = post(reply_learner_explanation_path, params: identity, as: :json)
  def failure_text(error)
    ProviderFailureText.new(ProviderFailure.classify(error), provider: user.provider, surface: :explanation_reply,
                            failed_at: Time.current, zone: user.effective_time_zone, variant: ProviderFailureText.variant_for(user))
  end
  def reply_attempts = LearnerExtraction.for(exercise.reload).reply_attempts
  def spend_reply_attempts(count) = count.times { LearnerExtraction.count_reply_attempt!(exercise) { Time.current } }
  def reply_box = Nokogiri::HTML.fragment(response.parsed_body["html"]).at_css("#learner-explanation-reply")
  def dashboard_reply
    get root_path
    Nokogiri::HTML(response.body).at_css("#learner-explanation-reply")
  end

  def asks_on_load? = Nokogiri::HTML(response.body).at_css("#learner-explanation")["data-learner-explanation-ask-reply-value"]

  it "stores a valid reply and shows it under the not-a-grade heading" do
    ask

    expect(response).to have_http_status(:ok)
    expect(calls.sole).to eq(concept: "N plus one", phrasing: "In your own words, what does N plus one do?", explanation: "One query per row.")
    expect(reply_attempts).to eq(1)
    expect(note.reload).to have_attributes(reply_requested_at: nil,
                                           explanation_reply: { "sound" => "You named the per-row query.",
                                                                "correction" => "Preloading adds one query, not none." })
    expect(reply_box.at_css("h3").text).to eq("Feedback on your explanation, not a grade")
    expect(reply_box.text).to include("What was sound: You named the per-row query.")
      .and include("One thing to correct: Preloading adds one query, not none.")
    expect(dashboard_reply.text).to include("What was sound: You named the per-row query.")
  end

  it "stores a correct explanation's reply with a null correction and shows no correction line" do
    replies.replace([ ExplanationReply::Reply.new(sound: "That is right.", correction: nil) ])

    ask

    expect(note.reload.explanation_reply).to eq("sound" => "That is right.", "correction" => nil)
    expect(reply_box.text).to include("What was sound: That is right.")
    expect(reply_box.text).not_to include("One thing to correct")
  end

  it "sends nothing but the concept, the phrasing and the explanation" do
    ask

    expect(calls.sole.keys).to contain_exactly(:concept, :phrasing, :explanation)
    expect(calls.sole.values.join).not_to include("ANSWER-TEXT", "REVIEW-TEXT", "NOTE-TEXT")
  end

  describe "the page states" do
    it "waits, and asks for the reply, while none has been asked for" do
      box = dashboard_reply

      expect(box.text).to include("Getting feedback…")
      expect(asks_on_load?).to eq("true")
      expect(box.at_css("button")).to be_nil
    end

    it "waits without asking again while another request holds the claim" do
      spend_reply_attempts(1)
      note.update!(reply_requested_at: Time.current)

      box = dashboard_reply

      expect(box.text).to include("Getting feedback…")
      expect(asks_on_load?).to eq("false")
    end

    it "offers Try again once after a failure, and nothing after the second" do
      replies.replace([ ProviderError::TimeoutError.new("slow"), ProviderError::TimeoutError.new("slow") ])

      ask
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["error"]).to eq(failure_text(ProviderError::TimeoutError.new("slow")).full)
      expect(response.parsed_body["failure"]).to eq("timeout")
      expect(reply_box.text).to include("No feedback this time. Your explanation is saved.")
      expect(reply_box.at_css("button").text).to eq("Try again")
      expect(reply_attempts).to eq(1)
      expect(note.reload).to have_attributes(reply_requested_at: nil, explanation_reply: nil)

      ask
      expect(reply_box.text).to include("No feedback this time. Your explanation is saved.")
      expect(reply_box.at_css("button")).to be_nil
      expect(dashboard_reply.at_css("button")).to be_nil
    end

    it "lets Try again succeed" do
      replies.replace([ ProviderError::TimeoutError.new("slow"), ExplanationReply::Reply.new(sound: "Right.", correction: nil) ])

      2.times { ask }

      expect(response).to have_http_status(:ok)
      expect(reply_attempts).to eq(2)
      expect(note.reload).to have_attributes(explanation_reply: { "sound" => "Right.", "correction" => nil })
    end

    it "words an out-of-credit failure through ProviderFailureText for the explanation reply, never as a rate limit" do
      error = ProviderError::BillingError.new("PROVIDER-SAID-THIS")
      replies.replace([ error ])

      ask

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["failure"]).to eq("out_of_credit")
      expect(response.parsed_body["error"]).to eq(failure_text(error).full)
      expect(response.parsed_body["error"]).to include(I18n.t("provider_failures.outcomes.explanation_reply"))
        .and include(I18n.t("provider_failures.saved.explanation_reply"))
      expect(response.parsed_body["error"]).not_to include("PROVIDER-SAID-THIS")
    end

    it "words a setup problem as the account's and logs it at error level with the user's id" do
      replies.replace([ SetupError.new("no provider") ])
      allow(Rails.logger).to receive(:error).and_call_original

      ask

      expect(response.parsed_body["failure"]).to eq("setup")
      expect(Rails.logger).to have_received(:error).with(/Setup error for user #{user.id} on explanation_reply/)
      expect(reply_box.at_css("button").text).to eq("Try again")
    end

    it "counts a malformed reply as a failure" do
      replies.replace([ ProviderError::InvalidResponseError.new("bad") ])

      ask

      expect(response).to have_http_status(:service_unavailable)
      expect(reply_box.at_css("button").text).to eq("Try again")
    end
  end

  it "refuses a third request with no call" do
    spend_reply_attempts(2)

    ask

    expect(response).to have_http_status(:conflict)
    expect(calls).to be_empty
    expect(reply_box.at_css("button")).to be_nil
  end

  it "makes one call for two requests at once: the second finds the claim held" do
    spend_reply_attempts(1)
    note.update!(reply_requested_at: 5.seconds.ago)

    ask

    expect(response).to have_http_status(:conflict)
    expect(calls).to be_empty
    expect(reply_attempts).to eq(1)
  end

  it "makes no call once a reply is stored, and answers with it" do
    spend_reply_attempts(1)
    note.update!(explanation_reply: { "sound" => "Right.", "correction" => nil })

    ask

    expect(response).to have_http_status(:ok)
    expect(calls).to be_empty
    expect(reply_box.text).to include("What was sound: Right.")
  end

  it "keeps a reply that arrives after its claim went stale and was taken by another request from overwriting that one" do
    allow_any_instance_of(AiService).to receive(:explanation_reply) do
      note.reload.update_columns(reply_requested_at: Time.current + 1.second)
      ExplanationReply::Reply.new(sound: "Late.", correction: nil)
    end

    ask

    expect(note.reload.explanation_reply).to be_nil
  end

  it "makes no call with the setting off, without the account's own key, or before an explanation is saved" do
    user.update!(learner_notes_enabled: false)
    ask
    expect(response).to have_http_status(:not_found)

    user.update!(learner_notes_enabled: true, api_keys: nil, provider: nil)
    ask

    user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test-key" })
    note.update!(explanation: nil)
    ask
    expect(response).to have_http_status(:unprocessable_content)

    expect(calls).to be_empty
    expect(reply_attempts).to eq(0)
  end

  describe "a note deleted while the reply is asked for" do
    it "answers with the refusal text as JSON when the explanation is deleted during the call, and stores nothing" do
      allow_any_instance_of(AiService).to receive(:explanation_reply) do
        LearnerNote.remove!(user, note.id, :explanation)
        ExplanationReply::Reply.new(sound: "Late.", correction: nil)
      end

      ask

      expect(response).to have_http_status(:conflict)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body["error"]).to eq(I18n.t("learner_notes.reply.no_explanation"))
      expect(note.reload).to have_attributes(explanation: nil, explanation_reply: nil)
    end

    it "answers with the refusal text as JSON when the set is started over during the call" do
      allow_any_instance_of(AiService).to receive(:explanation_reply) do
        exercise.reload.start_over!(exercise.daily_response)
        ExplanationReply::Reply.new(sound: "Late.", correction: nil)
      end

      ask

      expect(response).to have_http_status(:conflict)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body["error"]).to eq(I18n.t("learner_notes.reply.no_explanation"))
      expect(LearnerNote.exists?(note.id)).to be(false)
    end

    it "answers with the refusal text as JSON when the call fails after the note was deleted" do
      allow_any_instance_of(AiService).to receive(:explanation_reply) do
        LearnerNote.remove_all!(user)
        raise ProviderError::TimeoutError, "slow"
      end

      ask

      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body["error"]).to eq(I18n.t("learner_notes.reply.no_explanation"))
    end

    it "keeps the attempt counted on the set, so a new explanation the same day cannot ask twice more" do
      allow_any_instance_of(AiService).to receive(:explanation_reply) do
        LearnerNote.remove!(user, note.id, :explanation)
        ExplanationReply::Reply.new(sound: "Late.", correction: nil)
      end

      ask

      expect(reply_attempts).to eq(1)
    end
  end

  describe "a page showing an explanation that has since been replaced" do
    def page_identity
      get root_path
      box = Nokogiri::HTML(response.body).at_css("#learner-explanation")
      { note_id: box["data-learner-explanation-note-id-value"], explanation_stamp: box["data-learner-explanation-explanation-stamp-value"] }
    end

    def save_new_explanation(text = "NEW-TEXT")
      LearnerNote.save_explanation!(exercise.reload, section: "code_review", text: text, expected_scope: exercise.draft_scope,
                                                     expected_response_id: response_row.id.to_s)
    end

    def box_html = Nokogiri::HTML.fragment(response.parsed_body["box"].to_s)

    it "renders the note and its explanation's stamp on the saved box" do
      expect(page_identity).to eq(note_id: note.id.to_s, explanation_stamp: note.explanation_stamp)
      expect(note.explanation_stamp).to be_present
    end

    it "refuses an old tab once the explanation was deleted and another saved in a new row, with the current box and no attempt spent" do
      old_tab = page_identity
      LearnerNote.remove!(user, note.id, :note)
      LearnerNote.remove!(user, note.id, :explanation)
      expect(save_new_explanation).to be_a(LearnerNote)

      ask(old_tab)

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to eq(I18n.t("learner_notes.reply.moved"))
      expect(box_html.text).to include("NEW-TEXT")
      expect(calls).to be_empty
      expect(reply_attempts).to eq(0)
    end

    it "refuses an old tab once the same row holds a different explanation" do
      old_tab = page_identity
      LearnerNote.remove!(user, note.id, :explanation)
      expect(save_new_explanation.id).to eq(note.id)

      ask(old_tab)

      expect(response).to have_http_status(:conflict)
      expect(box_html.text).to include("NEW-TEXT")
      expect(calls).to be_empty
      expect(reply_attempts).to eq(0)
    end

    it "refuses a request that names no explanation" do
      ask({})

      expect(response).to have_http_status(:conflict)
      expect(calls).to be_empty
    end

    it "answers with the current box, not the reply, when the explanation is replaced during the call" do
      allow_any_instance_of(AiService).to receive(:explanation_reply) do
        LearnerNote.remove!(user, note.id, :explanation)
        save_new_explanation
        ExplanationReply::Reply.new(sound: "SOUND-FOR-OLD", correction: nil)
      end

      ask

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to eq(I18n.t("learner_notes.reply.moved"))
      expect(box_html.text).to include("NEW-TEXT")
      expect(response.parsed_body.to_s).not_to include("SOUND-FOR-OLD")
      expect(note.reload.explanation_reply).to be_nil
    end
  end
end
