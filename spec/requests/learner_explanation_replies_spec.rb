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

  def ask = post(reply_learner_explanation_path, as: :json)
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
    expect(note.reload).to have_attributes(reply_attempts: 1, reply_requested_at: nil,
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
      note.update!(reply_attempts: 1, reply_requested_at: Time.current)

      box = dashboard_reply

      expect(box.text).to include("Getting feedback…")
      expect(asks_on_load?).to eq("false")
    end

    it "offers Try again once after a failure, and nothing after the second" do
      replies.replace([ ProviderError::TimeoutError.new("slow"), ProviderError::TimeoutError.new("slow") ])

      ask
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["error"]).to eq("No feedback this time. Your explanation is saved.")
      expect(reply_box.text).to include("No feedback this time. Your explanation is saved.")
      expect(reply_box.at_css("button").text).to eq("Try again")
      expect(note.reload).to have_attributes(reply_attempts: 1, reply_requested_at: nil, explanation_reply: nil)

      ask
      expect(reply_box.text).to include("No feedback this time. Your explanation is saved.")
      expect(reply_box.at_css("button")).to be_nil
      expect(dashboard_reply.at_css("button")).to be_nil
    end

    it "lets Try again succeed" do
      replies.replace([ ProviderError::TimeoutError.new("slow"), ExplanationReply::Reply.new(sound: "Right.", correction: nil) ])

      2.times { ask }

      expect(response).to have_http_status(:ok)
      expect(note.reload).to have_attributes(reply_attempts: 2, explanation_reply: { "sound" => "Right.", "correction" => nil })
    end

    it "counts a malformed reply as a failure" do
      replies.replace([ ProviderError::InvalidResponseError.new("bad") ])

      ask

      expect(response).to have_http_status(:service_unavailable)
      expect(reply_box.at_css("button").text).to eq("Try again")
    end
  end

  it "refuses a third request with no call" do
    note.update!(reply_attempts: 2)

    ask

    expect(response).to have_http_status(:conflict)
    expect(calls).to be_empty
    expect(reply_box.at_css("button")).to be_nil
  end

  it "makes one call for two requests at once: the second finds the claim held" do
    note.update!(reply_attempts: 1, reply_requested_at: 5.seconds.ago)

    ask

    expect(response).to have_http_status(:conflict)
    expect(calls).to be_empty
    expect(note.reload.reply_attempts).to eq(1)
  end

  it "makes no call once a reply is stored, and answers with it" do
    note.update!(reply_attempts: 1, explanation_reply: { "sound" => "Right.", "correction" => nil })

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
    expect(note.reload.reply_attempts).to eq(0)
  end
end
