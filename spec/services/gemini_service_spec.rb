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

  # A 200 whose body is not JSON (a proxy's HTML page, a truncated body) has
  # to reach callers as an AiService::Error, which every one of them rescues;
  # a bare JSON::ParserError would escape those rescues.
  it "raises InvalidResponseError when a successful response body is not JSON" do
    service.instance_variable_set(:@conn, stubbed_connection([ [ 200, "<html>Bad gateway</html>" ] ]))

    expect { service.send(:call, system: "sys", prompt: "p") }
      .to raise_error(AiService::InvalidResponseError, /Gemini returned an unreadable response/)
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

    # Grading has the same billed-work problem at a smaller scale: a timed-out
    # grade has usually been produced and charged, and a retry pays for the
    # section again. Its budget exceeds READ_TIMEOUT so the guard treats it as
    # long_running.
    it "does not retry a grading call that times out" do
      attempts = []
      service.instance_variable_set(:@conn, recording_connection(attempts))

      expect {
        service.send(:call, system: "sys", prompt: "p", read_timeout: AiService::REVIEW_READ_TIMEOUT)
      }.to raise_error(AiService::TimeoutError, /Network error calling Gemini/)

      expect(attempts).to eq([ AiService::REVIEW_READ_TIMEOUT ])
    end

    it "still retries a short call that times out" do
      attempts = []
      service.instance_variable_set(:@conn, recording_connection(attempts))

      expect {
        service.send(:call, system: "sys", prompt: "p")
      }.to raise_error(AiService::TimeoutError, /Network error calling Gemini/)

      expect(attempts.size).to eq(GeminiService::RETRY_OPTIONS[:max] + 1)
    end
  end

  describe "retry/backoff" do
    # The backoff pauses for real between attempts; these assert how many
    # attempts run and what they raise, never how long they waited.
    before { allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep) }

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

  describe "a single-attempt call" do
    before { allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep) }

    it "makes one request for a 429 and raises" do
      responses = [ [ 429, "" ], [ 429, "" ], [ 429, "" ] ]
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      expect { service.send(:call, system: "sys", prompt: "p", single_attempt: true) }.to raise_error(AiService::RateLimitError)
      expect(responses.size).to eq(2)
    end

    it "makes one request for a timeout and raises" do
      attempts = 0
      conn = Faraday.new do |f|
        f.request :retry, GeminiService::RETRY_OPTIONS
        f.adapter(:test) { |stub| stub.post(GeminiService::API_URL) { attempts += 1; raise Faraday::TimeoutError } }
      end
      service.instance_variable_set(:@conn, conn)

      expect { service.send(:call, system: "sys", prompt: "p", single_attempt: true) }.to raise_error(AiService::TimeoutError)
      expect(attempts).to eq(1)
    end

    it "leaves an unflagged call on every retry attempt" do
      responses = [ [ 429, "" ], [ 429, "" ], [ 429, "" ], [ 429, "" ] ]
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      expect { service.send(:call, system: "sys", prompt: "p") }.to raise_error(AiService::RateLimitError)
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
        expect(parsed["model"]).to eq(GeminiService::DEFAULT_ROUTE[:model])
        expect(parsed["system_instruction"]).to eq("sys")
        expect(parsed["input"]).to eq("prompt text")
        expect(parsed["store"]).to eq(false)
        fake_response
      end

      result = service.send(:call, system: "sys", prompt: "prompt text")
      expect(result).to eq(text: "hello", input_tokens: 8, output_tokens: 12, truncated: false,
                           model: GeminiService::DEFAULT_ROUTE[:model], cache_read_tokens: 0, cache_write_tokens: 0)
    end

    # total_output_tokens leaves out thinking, which Gemini bills as output: a
    # live response reported total_tokens 736 = 25 input + 193 output + 518
    # thought. Recording only total_output_tokens under-counted that call by
    # three quarters.
    # Unlike Claude's input_tokens, total_input_tokens includes the cached
    # part: a live repeat of a 14,199-token prompt reported total_input_tokens
    # 14,199 with total_cached_tokens 8,171. Subtracting keeps tokens_in the
    # uncached input on both providers, so no token is priced twice.
    it "keeps cached tokens out of tokens_in, as Claude does" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "OK" } ] } ],
          "usage" => { "total_input_tokens" => 14_199, "total_cached_tokens" => 8_171, "total_output_tokens" => 1 }
        }.to_json)
      service.instance_variable_set(:@conn, instance_double(Faraday::Connection, post: fake_response))

      result = service.send(:call, system: "sys", prompt: "p")

      expect(result).to include(input_tokens: 6_028, cache_read_tokens: 8_171)
    end

    it "counts thought tokens as output and records cached tokens" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "17" } ] } ],
          "usage" => { "total_input_tokens" => 65, "total_output_tokens" => 193,
                       "total_thought_tokens" => 518, "total_cached_tokens" => 40, "total_tokens" => 776 }
        }.to_json)
      service.instance_variable_set(:@conn, instance_double(Faraday::Connection, post: fake_response))

      result = service.send(:call, system: "sys", prompt: "p")

      expect(result).to include(input_tokens: 25, output_tokens: 711, cache_read_tokens: 40, cache_write_tokens: 0)
    end

    # generation_config is the single key carrying BOTH the cap and the thinking
    # level, so its absence is what keeps an uncapped call untouched on both
    # counts. That matters most for the day's exercise generation, the one
    # uncapped caller: it wants the model's default effort, and sending
    # "minimal" there would quietly degrade every set to buy nothing, since
    # nothing is capping that budget in the first place.
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

    # Gemini's default model thinks at medium effort unless told otherwise, and
    # bills thinking into the same output budget the cap applies to, so a cap sent on its own can be spent
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

    # Truncation comes from the interaction's own status. The API documents
    # "incomplete" as completed with incomplete results, hitting max_tokens
    # being one cause. Token counts are not read at all: a live call capped at
    # 60 stopped at 56 output tokens with status "incomplete", which the old
    # output-reached-the-cap rule reported as complete.
    def gemini_reply(status:, output_tokens:)
      body = {
        "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "a reply" } ] } ],
        "usage" => { "total_output_tokens" => output_tokens }
      }
      body["status"] = status if status
      instance_double(Faraday::Response, success?: true, status: 200, body: body.to_json)
    end

    def truncated_for(status:, output_tokens:, max_tokens: nil)
      reply = gemini_reply(status: status, output_tokens: output_tokens)
      service.instance_variable_set(:@conn, instance_double(Faraday::Connection, post: reply))
      service.send(:call, system: "sys", prompt: "p", max_tokens: max_tokens)[:truncated]
    end

    it "reports an incomplete reply as truncated even below the cap" do
      expect(truncated_for(status: "incomplete", output_tokens: 56, max_tokens: 60)).to be(true)
    end

    it "does not report a completed reply as truncated even at or above the cap" do
      expect(truncated_for(status: "completed", output_tokens: 60, max_tokens: 60)).to be(false)
      expect(truncated_for(status: "completed", output_tokens: 75, max_tokens: 60)).to be(false)
    end

    it "reports an uncapped incomplete reply as truncated" do
      expect(truncated_for(status: "incomplete", output_tokens: 50_000)).to be(true)
    end

    it "does not fall back to token counts when the status is missing" do
      expect(truncated_for(status: nil, output_tokens: 60, max_tokens: 60)).to be(false)
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
