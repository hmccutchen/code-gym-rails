require "rails_helper"

RSpec.describe "Stored duck threads", type: :request do
  let(:user) { create_user_with_key }
  let!(:exercise) do
    DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" },
        "pattern"     => { "title" => "Service Objects", "question" => "When?" },
        "challenge"   => { "title" => "Build", "question" => "Implement X" }
      }
    )
  end
  let(:fake) { instance_double(ClaudeService) }

  before do
    allow(AiService).to receive(:for).and_return(fake)
    allow(fake).to receive(:duck_response).and_return("What runs first?")
    login_as(user)
  end

  def ask(message = "I'm stuck", version: 0, section: "code_review")
    post duck_thread_responses_path, params: { section: section, message: message, version: version }, as: :json
  end

  def clear(section = "code_review")
    delete duck_thread_responses_path, params: { section: section }, as: :json
  end

  def stored = DuckThread.for(exercise.reload)

  it "stores the exchange and returns the version the page sends next, without creating a DailyResponse" do
    ask

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok", "answer" => "What runs first?", "version" => 1)
    expect(stored.turns_for("code_review")).to eq([ { role: "user", content: "I'm stuck" },
                                                    { role: "assistant", content: "What runs first?" } ])
    expect(DailyResponse.count).to eq(0)
  end

  it "sends the provider the stored thread, not anything the page posted" do
    ask("first")
    ask("second", version: 1)

    expect(fake).to have_received(:duck_response).with(
      user, an_instance_of(DailyExercise), section: "code_review", message: "second",
      thread: [ { role: "user", content: "first" }, { role: "assistant", content: "What runs first?" } ]
    )
  end

  it "counts the cap from the stored thread" do
    ResponsesController::MAX_DUCK_TURNS_PER_SECTION.times { |turn| ask("turn #{turn}", version: turn) }

    ask("one more", version: ResponsesController::MAX_DUCK_TURNS_PER_SECTION)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to match(/used all #{ResponsesController::MAX_DUCK_TURNS_PER_SECTION} messages/)
    expect(fake).to have_received(:duck_response).exactly(ResponsesController::MAX_DUCK_TURNS_PER_SECTION).times
  end

  it "refuses a page whose version is behind before paying for a reply, and stores nothing" do
    ask
    ask("from another device", version: 0)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq(I18n.t("errors.responses.conversation_out_of_step"))
    expect(fake).to have_received(:duck_response).once
    expect(stored.user_turn_count("code_review")).to eq(1)
  end

  describe "a change that lands while the reply is on its way" do
    def during_the_call(&change)
      allow(fake).to receive(:duck_response) do
        change.call
        "What runs first?"
      end
    end

    it "drops the reply when the section is cleared, even if it held nothing yet" do
      during_the_call { DuckThread.clear!(DailyExercise.find(exercise.id), "code_review") }

      ask

      expect(response.parsed_body["error"]).to eq(I18n.t("errors.responses.conversation_out_of_step"))
      expect(stored.turns_for("code_review")).to eq([])
    end

    it "drops the reply when the set is regenerated, so it never lands on the new problems" do
      during_the_call { DailyExercise.find(exercise.id).update!(generated_at: 1.minute.from_now) }

      ask

      expect(response).to have_http_status(:unprocessable_content)
      expect(DuckThread.count).to eq(0)
    end

    it "drops the reply when the day is submitted" do
      during_the_call do
        DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                              answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
      end

      ask

      expect(response).to have_http_status(:unprocessable_content)
      expect(DuckThread.count).to eq(0)
    end
  end

  describe "DELETE" do
    it "empties the section, counts the clear and returns the new version" do
      ask
      clear

      expect(response.parsed_body).to eq("status" => "ok", "version" => 2)
      expect(stored.turns_for("code_review")).to eq([])
      expect(stored.cleared_count("code_review")).to eq(1)
    end

    it "gives the cap back, as Clear does today" do
      ResponsesController::MAX_DUCK_TURNS_PER_SECTION.times { |turn| ask("turn #{turn}", version: turn) }
      clear
      ask("after clearing", version: response.parsed_body["version"])

      expect(response).to have_http_status(:ok)
    end

    it "is refused once the day is submitted, so the kept thread is not erased" do
      ask
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
      clear

      expect(response).to have_http_status(:unprocessable_content)
      expect(stored.user_turn_count("code_review")).to eq(1)
    end

    it "refuses a section the day doesn't have" do
      clear("design_comparison")

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it "keeps the thread after submit" do
    ask
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)

    expect(stored.user_turn_count("code_review")).to eq(1)
  end

  it "deletes the thread when the day is started over" do
    ask
    response_row = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                         answers: { "code_review" => "draft" })

    delete start_over_response_path(response_row)

    expect(DuckThread.count).to eq(0)
  end

  it "never reads another user's thread" do
    ask
    other = create_user_with_key(email: "other@example.com")
    DailyExercise.create!(user: other, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: exercise.problem_set)
    login_as(other)

    ask("mine", version: 0)

    expect(fake).to have_received(:duck_response).with(other, anything, section: "code_review", message: "mine", thread: [])
  end

  describe "a page loaded before threads were stored" do
    let(:posted) do
      [ { role: "user", content: "before the deploy" }, { role: "assistant", content: "An earlier reply" } ]
    end

    def ask_old_shape(thread)
      post duck_thread_responses_path, params: { section: "code_review", message: "and now?", thread: thread }, as: :json
    end

    it "answers from the thread it posted, as today, and leaves the stored thread untouched" do
      ask("stored turn")
      before = stored.threads

      ask_old_shape(posted)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("status" => "ok", "answer" => "What runs first?")
      expect(fake).to have_received(:duck_response).with(
        user, anything, section: "code_review", message: "and now?", thread: posted
      )
      expect(stored.threads).to eq(before)
    end

    it "counts the cap from the thread it posted" do
      ask("stored turn")
      full = Array.new(ResponsesController::MAX_DUCK_TURNS_PER_SECTION) { posted }.flatten

      ask_old_shape(full)

      expect(response.parsed_body["error"]).to match(/used all/)
    end

    it "takes the old path for a first message, whose posted thread is empty" do
      ask_old_shape([])

      expect(response.parsed_body).to eq("status" => "ok", "answer" => "What runs first?")
      expect(fake).to have_received(:duck_response).with(user, anything, section: "code_review", message: "and now?", thread: [])
      expect(DuckThread.count).to eq(0)
    end

    it "keeps answering on every later message, never out of step" do
      ask_old_shape(posted)
      ask_old_shape(posted + [ { role: "user", content: "and now?" }, { role: "assistant", content: "What runs first?" } ])

      expect(response).to have_http_status(:ok)
      expect(DuckThread.count).to eq(0)
    end
  end

  describe "the dashboard" do
    it "renders the stored turns and version onto the thread, and nothing extra for a section without one" do
      ask

      get root_path

      duck = Nokogiri::HTML(response.body).css(".duck-thread")
      code_review = duck.find { |node| node["data-duck-thread-section-value"] == "code_review" }
      pattern     = duck.find { |node| node["data-duck-thread-section-value"] == "pattern" }
      expect(JSON.parse(code_review["data-duck-thread-turns-value"])).to eq(
        [ { "role" => "user", "content" => "I'm stuck" }, { "role" => "assistant", "content" => "What runs first?" } ]
      )
      expect(code_review["data-duck-thread-version-value"]).to eq("1")
      expect(pattern.attributes.keys).not_to include("data-duck-thread-turns-value", "data-duck-thread-version-value")
    end

    it "keeps a cleared section's version on the page, so the first message after a reload is answered" do
      ask
      clear

      get root_path
      code_review = Nokogiri::HTML(response.body).css(".duck-thread")
                            .find { |node| node["data-duck-thread-section-value"] == "code_review" }
      expect(code_review["data-duck-thread-turns-value"]).to be_nil
      expect(code_review["data-duck-thread-version-value"]).to eq("2")

      ask("after the reload", version: 2)
      expect(response).to have_http_status(:ok)
    end

    it "shows a regenerated day's sections with no thread" do
      ask
      exercise.update!(generated_at: 1.minute.from_now)

      get root_path

      expect(response.body).not_to include("data-duck-thread-turns-value")
    end
  end
end
