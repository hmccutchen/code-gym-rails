require "rails_helper"

RSpec.describe GeminiService do
  let(:service) { described_class.new("AIzaTestKey") }

  # Builds a connection with the service's real retry configuration but a
  # Faraday test adapter, so retry/backoff behavior can be exercised without
  # a real network call. `responses` is a queue of [status, body] pairs
  # popped one per request against API_URL.
  def stubbed_connection(responses)
    Faraday.new do |f|
      f.request :retry, GeminiService::RETRY_OPTIONS
      f.adapter :test do |stub|
        stub.post(GeminiService::API_URL) do
          status, body = responses.shift
          [ status, {}, body ]
        end
      end
    end
  end

  def success_body(text: "hello")
    {
      "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => text } ] } ],
      "usage" => { "total_input_tokens" => 1, "total_output_tokens" => 1 }
    }.to_json
  end

  describe "#build_connection" do
    it "sets the Gemini auth header" do
      conn = service.send(:build_connection)
      expect(conn.headers["x-goog-api-key"]).to eq("AIzaTestKey")
    end

    it "bounds the request so a hung provider cannot block a thread forever" do
      conn = service.send(:build_connection)
      expect(conn.options.open_timeout).to eq(AiService::OPEN_TIMEOUT)
      expect(conn.options.timeout).to eq(AiService::READ_TIMEOUT)
    end
  end

  describe "per-call read budget" do
    # Records what each attempt actually saw, so the assertions below are about
    # the request that reached the adapter rather than the connection default.
    def recording_connection(attempts, raise_timeout: true)
      Faraday.new do |f|
        f.request :retry, GeminiService::RETRY_OPTIONS.merge(interval: 0, max_interval: 0)
        f.adapter :test do |stub|
          stub.post(GeminiService::API_URL) do |env|
            attempts << env.request.timeout
            raise Faraday::TimeoutError, "Net::ReadTimeout" if raise_timeout

            [ 200, {}, success_body ]
          end
        end
      end
    end

    it "applies the caller's read timeout to the request itself" do
      attempts = []
      service.instance_variable_set(:@conn, recording_connection(attempts, raise_timeout: false))

      service.send(:call, system: "sys", prompt: "p", read_timeout: AiService::GENERATION_READ_TIMEOUT)

      expect(attempts).to eq([ AiService::GENERATION_READ_TIMEOUT ])
    end

    # A read timeout means the provider very likely finished — and billed — the
    # work; we just stopped listening. Retrying a generation therefore pays for
    # the whole problem set up to three times over to produce one failure.
    it "does not retry a generation that times out" do
      attempts = []
      service.instance_variable_set(:@conn, recording_connection(attempts))

      expect {
        service.send(:call, system: "sys", prompt: "p", read_timeout: AiService::GENERATION_READ_TIMEOUT)
      }.to raise_error(AiService::TimeoutError, /Network error calling Gemini/)

      expect(attempts.size).to eq(1)
    end

    it "still retries a short review call that times out" do
      attempts = []
      service.instance_variable_set(:@conn, recording_connection(attempts))

      expect {
        service.send(:call, system: "sys", prompt: "p")
      }.to raise_error(AiService::TimeoutError, /Network error calling Gemini/)

      expect(attempts.size).to eq(GeminiService::RETRY_OPTIONS[:max] + 1)
    end
  end

  describe "retry/backoff" do
    it "raises a timeout-specific error when the provider never responds" do
      conn = Faraday.new do |f|
        f.request :retry, GeminiService::RETRY_OPTIONS.merge(max: 0)
        f.adapter :test do |stub|
          stub.post(GeminiService::API_URL) { raise Faraday::TimeoutError }
        end
      end
      service.instance_variable_set(:@conn, conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::TimeoutError, /Network error calling Gemini/)
    end

    it "raises a plain error for a non-timeout network failure" do
      conn = Faraday.new do |f|
        f.adapter :test do |stub|
          stub.post(GeminiService::API_URL) { raise Faraday::ConnectionFailed, "no route" }
        end
      end
      service.instance_variable_set(:@conn, conn)

      error = nil
      begin
        service.send(:call, system: "sys", prompt: "prompt")
      rescue AiService::Error => e
        error = e
      end

      expect(error).to be_a(AiService::Error)
      expect(error).not_to be_a(AiService::TimeoutError)
      expect(error.message).to match(/Network error calling Gemini/)
    end

    it "retries a 429 and eventually succeeds" do
      responses = [ [ 429, "" ], [ 200, success_body ] ]
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      result = service.send(:call, system: "sys", prompt: "prompt")

      expect(result[:text]).to eq("hello")
      expect(responses).to be_empty
    end

    it "raises RateLimitError once retries are exhausted on a persistent 429" do
      responses = [ [ 429, "" ], [ 429, "" ], [ 429, "" ], [ 429, "" ] ]
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::RateLimitError)
      # 3 total attempts (max: 2 retries) — one response left unused.
      expect(responses.size).to eq(1)
    end

    it "raises AuthenticationError immediately on a 401, without retrying" do
      responses = [ [ 401, { "error" => { "message" => "API key not valid" } }.to_json ], [ 200, success_body ] ]
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::AuthenticationError, "API key not valid")
      # The 401 isn't in retry_statuses, so only one request is made — the
      # second stubbed response is never consumed.
      expect(responses.size).to eq(1)
    end
  end

  describe "#call" do
    it "posts the Gemini-shaped request body and extracts text + usage from the model_output step" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "steps" => [
            { "type" => "thought" },
            { "type" => "model_output", "content" => [ { "type" => "text", "text" => "hello" } ] }
          ],
          "usage" => { "total_input_tokens" => 8, "total_output_tokens" => 12 }
        }.to_json)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |url, body|
        expect(url).to eq(GeminiService::API_URL)
        parsed = JSON.parse(body)
        expect(parsed["model"]).to eq(GeminiService::MODEL)
        expect(parsed["system_instruction"]).to eq("sys")
        expect(parsed["input"]).to eq("prompt text")
        expect(parsed["store"]).to eq(false)
        fake_response
      end

      result = service.send(:call, system: "sys", prompt: "prompt text")
      expect(result).to eq(text: "hello", input_tokens: 8, output_tokens: 12, truncated: false)
    end

    it "omits generation_config entirely when no max_tokens override is given" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "hi" } ] } ],
          "usage" => {}
        }.to_json)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |_url, body|
        expect(JSON.parse(body)).not_to have_key("generation_config")
        fake_response
      end

      service.send(:call, system: "sys", prompt: "p")
    end

    it "nests a max_tokens override under generation_config, where the Interactions API reads it" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "hi" } ] } ],
          "usage" => {}
        }.to_json)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |_url, body|
        parsed = JSON.parse(body)
        expect(parsed["generation_config"]).to eq(
          "max_output_tokens" => AiService::DUCK_RESPONSE_MAX_TOKENS,
          "thinking_level"    => GeminiService::MINIMAL_THINKING_LEVEL
        )
        expect(parsed).not_to have_key("max_output_tokens")
        fake_response
      end

      service.send(:call, system: "sys", prompt: "p", max_tokens: AiService::DUCK_RESPONSE_MAX_TOKENS)
    end

    # MODEL thinks at medium effort by default and bills thinking into the same
    # output budget the cap applies to, so a cap sent on its own can be spent
    # reasoning before any reply text is emitted. ClaudeService pairs a cap with
    # `thinking: disabled` for exactly this reason; this is the Gemini half of
    # that rule, and it is the whole point of the cap being honoured at all.
    it "asks for minimal thinking whenever it caps the budget, so the cap is not spent reasoning" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "hi" } ] } ],
          "usage" => {}
        }.to_json)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |_url, body|
        expect(JSON.parse(body).dig("generation_config", "thinking_level"))
          .to eq(GeminiService::MINIMAL_THINKING_LEVEL)
        fake_response
      end

      service.send(:call, system: "sys", prompt: "p", max_tokens: 150)
    end

    # The other half: an uncapped call is the day's generation, which wants the
    # model's default effort. Sending minimal there would quietly degrade every
    # exercise set to buy nothing, since nothing is capping that budget.
    it "leaves an uncapped call's thinking effort alone" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "hi" } ] } ],
          "usage" => {}
        }.to_json)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |_url, body|
        expect(JSON.parse(body)).not_to have_key("generation_config")
        fake_response
      end

      service.send(:call, system: "sys", prompt: "p")
    end

    # The Interactions API response has no stop/finish-reason field to read
    # (unlike Claude's stop_reason), so without this call_and_log's
    # truncation check would be silently always-false for Gemini — a capped
    # call that actually got cut off would come back as a normal, un-flagged
    # response instead of raising AiService::TruncatedResponseError.
    it "reports truncated when a capped call's output lands at or past the requested ceiling" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "cut off mid" } ] } ],
          "usage" => { "total_output_tokens" => 150 }
        }.to_json)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      result = service.send(:call, system: "sys", prompt: "p", max_tokens: 150)
      expect(result[:truncated]).to be(true)
    end

    it "does not report truncated when a capped call finishes under the ceiling" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "a short reply" } ] } ],
          "usage" => { "total_output_tokens" => 40 }
        }.to_json)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      result = service.send(:call, system: "sys", prompt: "p", max_tokens: 150)
      expect(result[:truncated]).to be(false)
    end

    it "never reports truncated on an uncapped call, regardless of output size" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "a very long reply" } ] } ],
          "usage" => { "total_output_tokens" => 50_000 }
        }.to_json)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      result = service.send(:call, system: "sys", prompt: "p")
      expect(result[:truncated]).to be(false)
    end

    it "raises AiService::Error on a non-success response" do
      fake_response = instance_double(Faraday::Response, success?: false, status: 503, body: "overloaded")
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error, /Gemini API error 503/)
    end

    it "surfaces the provider's own error message when the body includes one" do
      body = {
        "error" => {
          "code"    => 429,
          "message" => "Resource has been exhausted (e.g. check quota).",
          "status"  => "RESOURCE_EXHAUSTED"
        }
      }.to_json
      fake_response = instance_double(Faraday::Response, success?: false, status: 429, body: body)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error, "Resource has been exhausted (e.g. check quota).")
    end

    it "does not leak the raw response body into the exception message" do
      huge_body = "error detail " * 100
      fake_response = instance_double(Faraday::Response, success?: false, status: 503, body: huge_body)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error) { |e| expect(e.message).not_to include(huge_body) }
    end

    it "logs a truncated snippet of the raw response body server-side" do
      huge_body = "z" * 1000
      fake_response = instance_double(Faraday::Response, success?: false, status: 503, body: huge_body)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect(Rails.logger).to receive(:error) do |msg|
        expect(msg).to include("Gemini API error 503 body")
        expect(msg).to include("truncated, #{huge_body.bytesize} bytes total")
      end

      expect { service.send(:call, system: "sys", prompt: "prompt") }.to raise_error(AiService::Error)
    end
  end

  describe "#call with history" do
    def captured_body(**kwargs)
      body = nil
      conn = Faraday.new do |f|
        f.adapter :test do |stub|
          stub.post(GeminiService::API_URL) do |env|
            body = JSON.parse(env.body)
            [ 200, {}, { "steps" => [ { "type" => "model_output",
                                        "content" => [ { "type" => "text", "text" => "ok" } ] } ],
                         "usage" => { "total_input_tokens" => 1, "total_output_tokens" => 1 } }.to_json ]
          end
        end
      end
      service.instance_variable_set(:@conn, conn)
      service.send(:call, system: "sys", prompt: "new turn", **kwargs)
      body
    end

    # The Interactions API has no messages array; prior turns are folded back
    # into the single input string. See the design doc's Gemini section.
    it "folds prior turns into the input string" do
      history = [
        { role: "user",      content: "first question" },
        { role: "assistant", content: "first reply" }
      ]

      expect(captured_body(history: history)["input"]).to eq(
        "Conversation so far:\nThem: first question\nYou: first reply\n\nnew turn"
      )
    end

    it "sends the prompt unchanged when history is empty" do
      expect(captured_body["input"]).to eq("new turn")
    end
  end
end
