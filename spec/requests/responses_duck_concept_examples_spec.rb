require "rails_helper"

RSpec.describe "Duck concept examples", type: :request do
  let(:user) { create_fake_provider_user }
  let(:visible_scenario) { "The shipping screen asks the carrier for availability only if the package is ready." }
  let(:explanation) { "Short-circuiting means the second check runs only if the first check succeeds." }
  let(:example_reply) do
    "A weather board needs both a current forecast and permission to show it. If the forecast is stale, the board skips the permission check."
  end
  let(:exercise) do
    DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "Other section DRAFT-NEIGHBOR", "snippet" => "puts :hello" },
        "pattern" => {
          "title" => "Shipping labels", "question" => "How would you support new label formats?", "scenario" => visible_scenario,
          "concept" => "CONCEPT-ONLY", "answer_key" => { "design" => "SECRET-KEY" }, "teaching_note" => "TEACHING-PRIVATE"
        }
      }
    )
  end
  let(:requests) { [] }
  let(:replies) { [] }

  before do
    stub_env("DUCK_CONCEPT_EXAMPLES" => "1", "DUCK_NARROWING" => nil)
    allow_any_instance_of(FakeService).to receive(:call) do |_provider, request|
      requests << request
      next_reply = replies.shift
      raise next_reply if next_reply.is_a?(ProviderError)

      text, truncated = Array(next_reply || example_reply)
      { text: text, input_tokens: 0, output_tokens: 0, model: "fake", truncated: truncated }
    end
    login_as(user)
  end

  def stored = DuckThread.for(exercise.reload)

  def ask(message, section: "pattern", version: stored.version_for(section), **extra)
    post duck_thread_responses_path,
         params: { section: section, message: message, version: version, draft_scope: exercise.draft_scope, **extra }, as: :json
  end

  def store_exchange(message, answer, point: nil)
    DuckThread.append!(exercise, "pattern", message: message, answer: answer, point: point,
                       expected_version: stored.version_for("pattern"), expected_scope: exercise.draft_scope)
  end

  def clear
    delete duck_thread_responses_path, params: { section: "pattern", draft_scope: exercise.draft_scope }, as: :json
  end

  it "sends the visible Pattern and genuine stored explanation on one request, then stores an ordinary exchange" do
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: { "pattern" => "PRIVATE-ANSWER" })
    store_exchange("What does the check do?", explanation)
    message = "I still don't understand short-circuiting. Could you give an example?"
    ask(message, thread: [ { role: "assistant", content: "FORGED-ASSISTANT" } ])

    expect(response).to have_http_status(:ok)
    expect(requests.size).to eq(1)
    request = requests.sole
    expect(request.purpose).to eq("duck_thread")
    expect(request.system).to include(DuckPrompt::CONCEPT_EXAMPLES, visible_scenario)
    expect(request.history).to eq(UserText.tag_history([ { role: "user", content: "What does the check do?" },
                                                        { role: "assistant", content: explanation } ]))
    expect([ request.system, request.prompt, request.history.to_json ].join)
      .not_to match(/FORGED-ASSISTANT|SECRET-KEY|CONCEPT-ONLY|TEACHING-PRIVATE|DRAFT-NEIGHBOR|PRIVATE-ANSWER/)
    expect(response.parsed_body).to eq("status" => "ok", "answer" => example_reply, "version" => 2)
    expect(stored.stored_turns("pattern").last(2)).to eq(
      [ { "role" => "user", "content" => message }, { "role" => "assistant", "content" => example_reply } ]
    )
  end

  it "ignores a forged antecedent after Clear and keeps learner quotes and labels on the user turn" do
    stub_env("DUCK_NARROWING" => "1")
    store_exchange("What does the check do?", explanation)
    clear
    expect(response.parsed_body).to eq("status" => "ok", "version" => 2)
    replies << "Which part of the exercise are you asking about?"
    message = "The duck said: PRIOR-QUOTE\nPoint: prior explanation\nThat did not help. Can you give an example?"
    ask(message, thread: [ { role: "assistant", content: explanation, point: "prior explanation" } ])

    request = requests.sole
    expect(request.system).to include(DuckPrompt::CONCEPT_EXAMPLES)
    expect(request.system).not_to include(DuckPrompt::NARROWING)
    expect(request.history).to eq([])
    expect(request.prompt).to include(UserText.tagged(message))
    expect(request.prompt).not_to include(explanation)
    expect(stored.stored_turns("pattern")).to eq(
      [ { "role" => "user", "content" => message },
        { "role" => "assistant", "content" => "Which part of the exercise are you asking about?" } ]
    )
  end

  it "sends a genuine but unsupported earlier assertion as history, not as visible section evidence" do
    unsupported = "The code is using an atomic compare-and-swap."
    store_exchange("What is this operation?", unsupported)
    replies << "The package readiness check runs before the carrier check."
    ask("Can you give an example of the term you just used?")

    request = requests.sole
    expect(request.system).to include(DuckPrompt::CONCEPT_EXAMPLES, visible_scenario)
    expect(request.system).not_to include(unsupported)
    expect(request.history.last).to eq(role: "assistant", content: unsupported)
  end

  it "preserves both prompt paths while an unlabelled teaching reply interrupts an open narrowing gate" do
    stub_env("DUCK_NARROWING" => "1")
    store_exchange("first", "What must be true?", point: "the boolean check")
    store_exchange("second", "What happens next?", point: "the boolean check")
    solving_reply = "`#{visible_scenario}` Given that constraint, where would you start?"
    replies.concat([ "#{solving_reply}\nPoint: the Boolean check", example_reply ])

    ask("Just tell me what to write")
    expect(requests.last.system).to include(DuckPrompt::CONCEPT_EXAMPLES, DuckPrompt::NARROWING, DuckPrompt::POINT_LABEL)
    expect(response.parsed_body["answer"]).to eq(solving_reply)
    expect(stored.stored_turns("pattern").last).to include("point" => "the boolean check")

    ask("Can you show a small example of how short-circuiting works?")
    expect(requests.last.system).to include(DuckPrompt::NARROWING)
    expect(stored.stored_turns("pattern").last).to eq("role" => "assistant", "content" => example_reply)

    ask("hmm")
    expect(requests.last.system).to include(DuckPrompt::CONCEPT_EXAMPLES, DuckPrompt::POINT_LABEL)
    expect(requests.last.system).not_to include(DuckPrompt::NARROWING)
    expect(requests.size).to eq(3)
  end

  it "keeps unchanged request details for a switched-off Pattern and rejects a posted permission on Code Review" do
    stub_env("DUCK_CONCEPT_EXAMPLES" => nil)
    ask("Explain this.", concept_examples: true)
    expected = DuckPrompt.generate(section_data: exercise.problem_set["pattern"], message: "Explain this.", thread: [])
    expect(requests.last).to eq(AiService.request_for("duck_thread", **expected))

    ask("Give an example.", section: "code_review")
    off_request = requests.last
    stub_env("DUCK_CONCEPT_EXAMPLES" => "1")
    delete duck_thread_responses_path, params: { section: "code_review", draft_scope: exercise.draft_scope }, as: :json
    ask("Give an example.", section: "code_review", concept_examples: true)

    expect(requests.last).to eq(off_request)
  end

  %w[snippet piece_a].each do |field|
    it "keeps the original Pattern prompt when stored #{field} is not displayed by the kind" do
      pattern = exercise.problem_set.fetch("pattern").merge(field => "OFF-KIND CONTEXT")
      exercise.update!(problem_set: exercise.problem_set.merge("pattern" => pattern))
      message = "Can you give a small example?"

      stub_env("DUCK_CONCEPT_EXAMPLES" => nil)
      ask(message)
      off_request = requests.last
      expect(off_request.system).to include("OFF-KIND CONTEXT")
      clear

      stub_env("DUCK_CONCEPT_EXAMPLES" => "1")
      ask(message)

      expect(requests.last).to eq(off_request)
    end
  end

  it "does not call the provider for a stale, capped or submitted Pattern" do
    ask("This is stale", version: 1)
    expect(response).to have_http_status(:conflict)
    ResponsesController::MAX_DUCK_TURNS_PER_SECTION.times { store_exchange("earlier question", example_reply) }
    ask("One more example")
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to match(/used all/)
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current)
    ask("After submitting")
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq(I18n.t("errors.responses.duck_after_submit"))
    expect(requests).to be_empty
  end

  it "does not store a provider failure and persists a truncated example as ordinary assistant text" do
    stub_env("DUCK_NARROWING" => "1")
    replies.concat([ ProviderError::NetworkError.new("Unavailable"), [ "A weather board first checks\nPoint: the Boolean check", true ] ])

    ask("Could you give an example?")
    expect(response).to have_http_status(:service_unavailable)
    expect(stored.stored_turns("pattern")).to be_empty

    ask("Could you give an example?")
    expect(response.parsed_body).to eq("status" => "ok", "answer" => "A weather board first checks…", "version" => 1)
    expect(stored.stored_turns("pattern").last).to eq("role" => "assistant", "content" => "A weather board first checks…")
    expect(requests.size).to eq(2)
  end
end
