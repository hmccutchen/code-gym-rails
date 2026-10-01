require "rails_helper"

# A real GeminiService behind a canned HTTP reply, so the status reading in
# GeminiService and the shared truncation handling in AiService run together.
RSpec.describe "Gemini truncation through AiService" do
  include AuthHelpers

  let(:user) { create_user_with_key.tap { |u| u.update!(api_key: "AQ.test-key", provider: "gemini") } }
  let(:service) { AiService.for(user) }

  def reply_with(status:, text:, output_tokens: 56)
    body = {
      "status" => status,
      "steps"  => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => text } ] } ],
      "usage"  => { "total_input_tokens" => 21, "total_output_tokens" => output_tokens }
    }.to_json
    conn = Faraday.new { |f| f.adapter(:test) { |stub| stub.post(GeminiService::API_URL) { [ 200, {}, body ] } } }
    service.instance_variable_set(:@conn, conn)
  end

  it "is the Gemini provider" do
    expect(service).to be_a(GeminiService)
  end

  it "records usage, then raises, for an incomplete reply below the cap" do
    reply_with(status: "incomplete", text: "a reply cut off mid")

    expect {
      expect {
        service.send(:call_and_log, user, purpose: "explain_differently", system: "s", prompt: "p", max_tokens: 60)
      }.to raise_error(AiService::TruncatedResponseError, /did not finish its reply/)
    }.to change { ApiUsage.where(purpose: "explain_differently", model: GeminiService::DEFAULT_ROUTE[:model]).count }.by(1)

    expect(ApiUsage.last).to have_attributes(tokens_in: 21, tokens_out: 56)
  end

  describe "the thinking partner, which accepts a partial reply" do
    let(:exercise) do
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                            problem_set: { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" } })
    end

    it "returns nonempty partial text with an ellipsis" do
      reply_with(status: "incomplete", text: "Have you looked at what happens when")

      expect(service.duck_response(user, exercise, section: "code_review", message: "Where do I start?"))
        .to eq("Have you looked at what happens when…")
    end

    it "still fails an empty incomplete reply" do
      reply_with(status: "incomplete", text: "", output_tokens: 0)

      expect { service.duck_response(user, exercise, section: "code_review", message: "Where do I start?") }
        .to raise_error(AiService::InvalidResponseError, /empty duck response/)
    end

    it "returns a completed reply unchanged" do
      reply_with(status: "completed", text: "What does the loop do on its last pass?")

      expect(service.duck_response(user, exercise, section: "code_review", message: "Where do I start?"))
        .to eq("What does the loop do on its last pass?")
    end
  end
end
