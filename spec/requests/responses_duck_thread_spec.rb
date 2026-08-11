require "rails_helper"

RSpec.describe "POST /responses/duck_thread", type: :request do
  let(:user) { create_user_with_key }

  def create_exercise_for(owner, date: Date.current, problem_set: nil)
    DailyExercise.create!(
      user: owner, date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: problem_set || {
        "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" },
        "pattern"     => { "title" => "Service Objects", "question" => "When?" },
        "challenge"   => { "title" => "Build", "question" => "Implement X" }
      }
    )
  end

  def stub_answer(text = "What would happen if this ran a thousand times?")
    fake = instance_double(ClaudeService)
    allow(AiService).to receive(:for).and_return(fake)
    allow(fake).to receive(:duck_response).and_return(text)
    fake
  end

  it "returns the guiding question without creating any DailyResponse or writing to any table" do
    create_exercise_for(user)
    fake = stub_answer("What's the first thing that runs in that loop?")
    login_as(user)

    expect(DailyResponse.count).to eq(0)

    expect {
      post duck_thread_responses_path, params: { section: "code_review", message: "I'm stuck", thread: [] }, as: :json
    }.not_to change(DailyResponse, :count)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq("status" => "ok", "answer" => "What's the first thing that runs in that loop?")
    expect(fake).to have_received(:duck_response).with(
      user, an_instance_of(DailyExercise), section: "code_review", message: "I'm stuck", thread: []
    )
    expect(DailyResponse.count).to eq(0)
  end

  it "is available when a response row exists for today but isn't submitted yet" do
    exercise = create_exercise_for(user)
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: { "code_review" => "wip" })
    stub_answer
    login_as(user)

    post duck_thread_responses_path, params: { section: "code_review", message: "still stuck", thread: [] }, as: :json

    expect(response).to have_http_status(:ok)
  end

  it "returns 422 once today's response has been submitted, without calling the provider" do
    exercise = create_exercise_for(user)
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
    fake = stub_answer
    login_as(user)

    post duck_thread_responses_path, params: { section: "code_review", message: "too late?", thread: [] }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(fake).not_to have_received(:duck_response)
  end

  it "does not tell an already-submitted user to submit their answers" do
    exercise = create_exercise_for(user)
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
    stub_answer
    login_as(user)

    post duck_thread_responses_path, params: { section: "code_review", message: "too late?", thread: [] }, as: :json

    expect(JSON.parse(response.body)["error"]).not_to match(/submit your answers first/i)
    expect(JSON.parse(response.body)["error"]).to match(/before you submit/i)
  end

  describe "input bounds" do
    it "rejects an oversized message without calling the provider" do
      create_exercise_for(user)
      fake = stub_answer
      login_as(user)

      post duck_thread_responses_path,
           params: { section: "code_review",
                     message: "x" * (ResponsesController::MAX_DUCK_MESSAGE_LENGTH + 1), thread: [] },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(fake).not_to have_received(:duck_response)
    end

    it "accepts a message exactly at the limit" do
      create_exercise_for(user)
      fake = stub_answer
      login_as(user)

      post duck_thread_responses_path,
           params: { section: "code_review",
                     message: "x" * ResponsesController::MAX_DUCK_MESSAGE_LENGTH, thread: [] },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(fake).to have_received(:duck_response)
    end

    it "rejects a thread padded with more entries than the cap could ever produce" do
      create_exercise_for(user)
      fake = stub_answer
      login_as(user)

      # All-assistant, so the user-turn cap alone would let this through.
      padded = Array.new(ResponsesController::MAX_DUCK_THREAD_ENTRIES + 5) do
        { role: "assistant", content: "filler" }
      end

      post duck_thread_responses_path,
           params: { section: "code_review", message: "hi", thread: padded }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(fake).not_to have_received(:duck_response)
    end

    it "rejects a thread whose total content exceeds the byte budget" do
      create_exercise_for(user)
      fake = stub_answer
      login_as(user)

      oversized = Array.new(4) do
        { role: "assistant", content: "y" * (ResponsesController::MAX_DUCK_THREAD_BYTES / 3) }
      end

      post duck_thread_responses_path,
           params: { section: "code_review", message: "hi", thread: oversized }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(fake).not_to have_received(:duck_response)
    end

    it "measures the thread budget in bytes, so multi-byte content cannot slip past it" do
      create_exercise_for(user)
      fake = stub_answer
      login_as(user)

      # Under the budget by character count, over it by bytes (3 bytes each).
      multibyte = [ { role: "assistant", content: "あ" * (ResponsesController::MAX_DUCK_THREAD_BYTES / 2) } ]

      post duck_thread_responses_path,
           params: { section: "code_review", message: "hi", thread: multibyte }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(fake).not_to have_received(:duck_response)
    end

    # Regression guard: a flat MAX_DUCK_THREAD_BYTES undercounted its own
    # documented "generous enough that no honest session approaches it" claim
    # — 6 honest user turns at the max message length, in a worst-case
    # 4-byte-per-character language, already exceeded a flat 20_000-byte
    # budget after only 2-3 exchanges. This drives a full, cap-respecting,
    # every-message-at-the-character-limit CJK conversation through and
    # confirms it never trips the byte cap.
    it "lets a full, honest, cap-respecting conversation through even in a worst-case multi-byte language" do
      create_exercise_for(user)
      fake = stub_answer
      login_as(user)

      max_length_cjk_message = "あ" * ResponsesController::MAX_DUCK_MESSAGE_LENGTH
      thread_so_far = Array.new(ResponsesController::MAX_DUCK_TURNS_PER_SECTION - 1) {
        [ { role: "user", content: max_length_cjk_message }, { role: "assistant", content: "assistant reply" } ]
      }.flatten

      post duck_thread_responses_path,
           params: { section: "code_review", message: max_length_cjk_message, thread: thread_so_far },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(fake).to have_received(:duck_response)
    end
  end

  it "returns 422 for a section not present in today's exercise, without calling the provider" do
    create_exercise_for(user)
    fake = stub_answer
    login_as(user)

    post duck_thread_responses_path, params: { section: "architecture", message: "hi", thread: [] }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(fake).not_to have_received(:duck_response)
  end

  it "returns a JSON error body on 404, not an empty one — the client always calls res.json() before checking res.ok" do
    login_as(user)

    post duck_thread_responses_path, params: { section: "code_review", message: "hi", thread: [] }, as: :json

    expect(response).to have_http_status(:not_found)
    expect(JSON.parse(response.body)).to include("status" => "error")
  end

  it "returns 422 for a blank message, without calling the provider" do
    create_exercise_for(user)
    fake = stub_answer
    login_as(user)

    post duck_thread_responses_path, params: { section: "code_review", message: "   ", thread: [] }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(fake).not_to have_received(:duck_response)
  end

  it "tolerates a malformed thread element instead of raising a 500" do
    create_exercise_for(user)
    fake = stub_answer
    login_as(user)

    post duck_thread_responses_path,
      params: { section: "code_review", message: "help", thread: [ "oops", { role: "user", content: "real turn" } ] },
      as: :json

    expect(response).to have_http_status(:ok)
    expect(fake).to have_received(:duck_response).with(
      user, an_instance_of(DailyExercise), section: "code_review", message: "help",
      thread: [ { role: "user", content: "real turn" } ]
    )
  end

  it "tolerates a non-array thread instead of raising a 500" do
    create_exercise_for(user)
    stub_answer
    login_as(user)

    post duck_thread_responses_path, params: { section: "code_review", message: "help", thread: "not-an-array" }, as: :json

    expect(response).to have_http_status(:ok)
  end

  it "normalizes role case and drops turns with an unrecognized role" do
    create_exercise_for(user)
    fake = stub_answer
    login_as(user)

    post duck_thread_responses_path,
      params: { section: "code_review", message: "help", thread: [
        { role: "User", content: "mixed case" },
        { role: "SYSTEM", content: "not a real role" }
      ] },
      as: :json

    expect(response).to have_http_status(:ok)
    expect(fake).to have_received(:duck_response).with(
      user, an_instance_of(DailyExercise), section: "code_review", message: "help",
      thread: [ { role: "user", content: "mixed case" } ]
    )
  end

  it "counts case-insensitively toward the cap, so an unnormalized role can't dodge it" do
    create_exercise_for(user)
    fake = stub_answer
    login_as(user)

    mixed_case_capped_thread = Array.new(ResponsesController::MAX_DUCK_TURNS_PER_SECTION) { |i|
      [ { role: i.even? ? "user" : "User", content: "q#{i}" }, { role: "assistant", content: "a#{i}" } ]
    }.flatten

    post duck_thread_responses_path,
      params: { section: "code_review", message: "one more", thread: mixed_case_capped_thread },
      as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(fake).not_to have_received(:duck_response)
  end

  describe "cap enforcement" do
    it "rejects (422) once the submitted thread's user-turn count is already at the cap, without calling the provider" do
      create_exercise_for(user)
      fake = stub_answer
      login_as(user)

      capped_thread = Array.new(ResponsesController::MAX_DUCK_TURNS_PER_SECTION) { |i|
        [ { role: "user", content: "q#{i}" }, { role: "assistant", content: "a#{i}" } ]
      }.flatten

      post duck_thread_responses_path, params: { section: "code_review", message: "one more", thread: capped_thread }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(fake).not_to have_received(:duck_response)
    end

    it "allows a request one below the cap" do
      create_exercise_for(user)
      fake = stub_answer
      login_as(user)

      under_cap_thread = Array.new(ResponsesController::MAX_DUCK_TURNS_PER_SECTION - 1) { |i|
        [ { role: "user", content: "q#{i}" }, { role: "assistant", content: "a#{i}" } ]
      }.flatten

      post duck_thread_responses_path, params: { section: "code_review", message: "last one", thread: under_cap_thread }, as: :json

      expect(response).to have_http_status(:ok)
      expect(fake).to have_received(:duck_response)
    end
  end

  it "scopes to the current user — a different user's exercise/response is invisible, there is no id to probe" do
    other = create_user_with_key(email: "other@example.com")
    create_exercise_for(other)
    login_as(user) # no exercise of their own today

    post duck_thread_responses_path, params: { section: "code_review", message: "hi", thread: [] }, as: :json

    expect(response).to have_http_status(:not_found)
  end

  describe "the pre-written explanation request" do
    # It travels the same path as anything the user types: same endpoint, same
    # gate, same cap, no branch anywhere on the server.
    it "is handled as an ordinary message with no special-casing" do
      create_exercise_for(user)
      fake = stub_answer("Think of it like recounting a shopping list on every trip.")
      login_as(user)

      post duck_thread_responses_path,
           params: { section: "code_review", message: AiService::DUCK_EXPLAIN_REQUEST, thread: [] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(fake).to have_received(:duck_response).with(
        user, an_instance_of(DailyExercise),
        section: "code_review", message: AiService::DUCK_EXPLAIN_REQUEST, thread: []
      )
      expect(DailyResponse.count).to eq(0)
    end

    it "counts against the same turn cap as a typed message" do
      create_exercise_for(user)
      stub_answer
      login_as(user)

      thread = Array.new(ResponsesController::MAX_DUCK_TURNS_PER_SECTION) do |i|
        [ { role: "user", content: "q#{i}" }, { role: "assistant", content: "a#{i}" } ]
      end.flatten

      post duck_thread_responses_path,
           params: { section: "code_review", message: AiService::DUCK_EXPLAIN_REQUEST, thread: thread }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/used all/i)
    end

    it "is refused once the set is submitted, like any other duck message" do
      exercise = create_exercise_for(user)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "done" }, submitted_at: Time.current)
      stub_answer
      login_as(user)

      post duck_thread_responses_path,
           params: { section: "code_review", message: AiService::DUCK_EXPLAIN_REQUEST, thread: [] }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/before you submit/i)
    end
  end
end
