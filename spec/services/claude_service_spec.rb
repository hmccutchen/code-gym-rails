require "rails_helper"

RSpec.describe ClaudeService do
  let(:service) { described_class.new("sk-ant-test") }

  # Builds a connection with the service's real retry configuration but a
  # Faraday test adapter, so retry/backoff behavior can be exercised without
  # a real network call. `responses` is a queue of [status, body] pairs
  # popped one per request against API_URL.
  def stubbed_connection(responses)
    Faraday.new do |f|
      f.request :retry, ClaudeService::RETRY_OPTIONS
      f.adapter :test do |stub|
        stub.post(ClaudeService::API_URL) do
          status, body = responses.shift
          [ status, {}, body ]
        end
      end
    end
  end

  def success_body(text: "hello")
    { "content" => [ { "type" => "text", "text" => text } ], "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }.to_json
  end

  describe "#build_connection" do
    it "sets Anthropic auth headers" do
      conn = service.send(:build_connection)
      expect(conn.headers["x-api-key"]).to eq("sk-ant-test")
      expect(conn.headers["anthropic-version"]).to eq("2023-06-01")
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
        f.request :retry, ClaudeService::RETRY_OPTIONS.merge(interval: 0, max_interval: 0)
        f.adapter :test do |stub|
          stub.post(ClaudeService::API_URL) do |env|
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
    # the whole problem set up to three times over to produce one failure, so
    # the long-running path takes a timeout as final.
    it "does not retry a generation that times out" do
      attempts = []
      service.instance_variable_set(:@conn, recording_connection(attempts))

      expect {
        service.send(:call, system: "sys", prompt: "p", read_timeout: AiService::GENERATION_READ_TIMEOUT)
      }.to raise_error(AiService::TimeoutError, /Network error calling Claude/)

      expect(attempts.size).to eq(1)
    end

    it "still retries a short review call that times out" do
      attempts = []
      service.instance_variable_set(:@conn, recording_connection(attempts))

      expect {
        service.send(:call, system: "sys", prompt: "p")
      }.to raise_error(AiService::TimeoutError, /Network error calling Claude/)

      expect(attempts.size).to eq(ClaudeService::RETRY_OPTIONS[:max] + 1)
    end
  end

  describe "retry/backoff" do
    it "raises a timeout-specific error when the provider never responds" do
      conn = Faraday.new do |f|
        f.request :retry, ClaudeService::RETRY_OPTIONS.merge(max: 0)
        f.adapter :test do |stub|
          stub.post(ClaudeService::API_URL) { raise Faraday::TimeoutError }
        end
      end
      service.instance_variable_set(:@conn, conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::TimeoutError, /Network error calling Claude/)
    end

    it "raises a plain error for a non-timeout network failure" do
      conn = Faraday.new do |f|
        f.adapter :test do |stub|
          stub.post(ClaudeService::API_URL) { raise Faraday::ConnectionFailed, "no route" }
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
      expect(error.message).to match(/Network error calling Claude/)
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

    it "raises RateLimitError (not a generic Error) once retries are exhausted on a persistent 529" do
      responses = [ [ 529, "" ], [ 529, "" ], [ 529, "" ], [ 529, "" ] ]
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::RateLimitError)
      expect(responses.size).to eq(1)
    end

    it "raises AuthenticationError immediately on a 401, without retrying" do
      responses = [ [ 401, { "error" => { "message" => "invalid x-api-key" } }.to_json ], [ 200, success_body ] ]
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::AuthenticationError, "invalid x-api-key")
      # The 401 isn't in retry_statuses, so only one request is made — the
      # second stubbed response is never consumed.
      expect(responses.size).to eq(1)
    end
  end

  describe "#call" do
    it "posts the Anthropic-shaped request body and normalizes the response" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "content" => [ { "type" => "text", "text" => "hello" } ],
          "usage"   => { "input_tokens" => 10, "output_tokens" => 20 }
        }.to_json)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |url, body|
        expect(url).to eq(ClaudeService::API_URL)
        parsed = JSON.parse(body)
        expect(parsed["model"]).to eq(ClaudeService::MODEL)
        expect(parsed["system"]).to eq("sys")
        expect(parsed["messages"]).to eq([ { "role" => "user", "content" => "prompt text" } ])
        fake_response
      end

      result = service.send(:call, system: "sys", prompt: "prompt text")
      expect(result).to eq(text: "hello", input_tokens: 10, output_tokens: 20, truncated: false)
    end

    it "finds the text block even when a thinking block precedes it" do
      body = {
        "content" => [
          { "type" => "thinking", "thinking" => "reasoning about the answer" },
          { "type" => "text", "text" => "hello" }
        ],
        "usage" => { "input_tokens" => 10, "output_tokens" => 20 }
      }.to_json
      fake_response = instance_double(Faraday::Response, success?: true, status: 200, body: body)
      service.instance_variable_set(:@conn, instance_double(Faraday::Connection, post: fake_response))

      expect(service.send(:call, system: "sys", prompt: "prompt text")[:text]).to eq("hello")
    end

    it "sends MAX_TOKENS as the request's output budget" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200, body: success_body)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |_url, body|
        expect(JSON.parse(body)["max_tokens"]).to eq(ClaudeService::MAX_TOKENS)
        fake_response
      end

      service.send(:call, system: "sys", prompt: "prompt text")
    end

    # A three-section review (prose arrays plus a structural improved_code
    # block per section) overran the original 2500-token budget and came back
    # truncated mid-string. This floor is the actual regression guard; the
    # test above only proves the constant reaches the request.
    it "keeps an output budget large enough for a full three-section review" do
      expect(ClaudeService::MAX_TOKENS).to be >= 8_000
    end

    it "does not send a thinking override when max_tokens is not overridden" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200, body: success_body)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |_url, body|
        expect(JSON.parse(body)).not_to have_key("thinking")
        fake_response
      end

      service.send(:call, system: "sys", prompt: "prompt text")
    end

    # claude-sonnet-5 thinks by default and max_tokens caps thinking + reply
    # text together (see the MAX_TOKENS comment above). A caller-supplied
    # max_tokens is by construction tighter than the generous default, so
    # without this the model could spend the whole budget on thinking and
    # emit no reply text at all — a fully valid request coming back
    # truncated/empty and surfacing as a 503.
    it "disables thinking when a caller overrides max_tokens with a tight budget" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200, body: success_body)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |_url, body|
        parsed = JSON.parse(body)
        expect(parsed["max_tokens"]).to eq(150)
        expect(parsed["thinking"]).to eq("type" => "disabled")
        fake_response
      end

      service.send(:call, system: "sys", prompt: "prompt text", max_tokens: 150)
    end

    it "reports truncation when the model stopped at the output cap" do
      body = {
        "content"     => [ { "type" => "text", "text" => '{"code_review": {"correct": ["half a sen' } ],
        "stop_reason" => "max_tokens",
        "usage"       => { "input_tokens" => 10, "output_tokens" => 2500 }
      }.to_json
      fake_response = instance_double(Faraday::Response, success?: true, status: 200, body: body)
      service.instance_variable_set(:@conn, instance_double(Faraday::Connection, post: fake_response))

      # Reported as data, not raised here: AiService#call_and_log owns the
      # policy, so the billed usage is recorded before the failure propagates.
      expect(service.send(:call, system: "sys", prompt: "prompt text")[:truncated]).to be(true)
    end

    it "does not report truncation for a normal end_turn stop reason" do
      body = {
        "content"     => [ { "type" => "text", "text" => "hello" } ],
        "stop_reason" => "end_turn",
        "usage"       => { "input_tokens" => 10, "output_tokens" => 20 }
      }.to_json
      fake_response = instance_double(Faraday::Response, success?: true, status: 200, body: body)
      service.instance_variable_set(:@conn, instance_double(Faraday::Connection, post: fake_response))

      result = service.send(:call, system: "sys", prompt: "prompt text")
      expect(result[:text]).to eq("hello")
      expect(result[:truncated]).to be(false)
    end

    it "raises AiService::Error on a non-success response" do
      fake_response = instance_double(Faraday::Response, success?: false, status: 500, body: "boom")
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error, /Claude API error 500/)
    end

    it "surfaces the provider's own error message when the body includes one" do
      body = {
        "type"  => "error",
        "error" => { "type" => "insufficient_quota", "message" => "Your credit balance is too low to access the Anthropic API." }
      }.to_json
      fake_response = instance_double(Faraday::Response, success?: false, status: 400, body: body)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error, "Your credit balance is too low to access the Anthropic API.")
    end

    it "does not leak the raw response body into the exception message" do
      huge_body = "error detail " * 100
      fake_response = instance_double(Faraday::Response, success?: false, status: 500, body: huge_body)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error) { |e| expect(e.message).not_to include(huge_body) }
    end

    it "logs a truncated snippet of the raw response body server-side" do
      huge_body = "y" * 1000
      fake_response = instance_double(Faraday::Response, success?: false, status: 500, body: huge_body)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect(Rails.logger).to receive(:error) do |msg|
        expect(msg).to include("Claude API error 500 body")
        expect(msg).to include("truncated, #{huge_body.bytesize} bytes total")
      end

      expect { service.send(:call, system: "sys", prompt: "prompt") }.to raise_error(AiService::Error)
    end

    it "wraps system in a cache_control content block when cache_system is true" do
      captured_body = nil
      conn = instance_double(Faraday::Connection)
      allow(conn).to receive(:post) do |_url, body|
        captured_body = JSON.parse(body)
        instance_double(Faraday::Response, success?: true, status: 200, body: {
          "content" => [ { "type" => "text", "text" => "hello" } ],
          "usage"   => { "input_tokens" => 1, "output_tokens" => 1 }
        }.to_json)
      end
      service.instance_variable_set(:@conn, conn)

      service.send(:call, system: "shared context", prompt: "prompt text", cache_system: true)

      expect(captured_body["system"]).to eq(
        [ { "type" => "text", "text" => "shared context", "cache_control" => { "type" => "ephemeral" } } ]
      )
    end

    it "sends system as a plain string when cache_system is false (default)" do
      captured_body = nil
      conn = instance_double(Faraday::Connection)
      allow(conn).to receive(:post) do |_url, body|
        captured_body = JSON.parse(body)
        instance_double(Faraday::Response, success?: true, status: 200, body: {
          "content" => [ { "type" => "text", "text" => "hello" } ],
          "usage"   => { "input_tokens" => 1, "output_tokens" => 1 }
        }.to_json)
      end
      service.instance_variable_set(:@conn, conn)

      service.send(:call, system: "sys", prompt: "prompt text")

      expect(captured_body["system"]).to eq("sys")
    end
  end

  describe "#call with history" do
    def captured_body(**kwargs)
      body = nil
      conn = Faraday.new do |f|
        f.adapter :test do |stub|
          stub.post(ClaudeService::API_URL) do |env|
            body = JSON.parse(env.body)
            [ 200, {}, success_body ]
          end
        end
      end
      service.instance_variable_set(:@conn, conn)
      service.send(:call, system: "sys", prompt: "new turn", **kwargs)
      body
    end

    it "sends prior turns as real messages, with the new turn last" do
      history = [
        { role: "user",      content: "first question" },
        { role: "assistant", content: "first reply" }
      ]

      expect(captured_body(history: history)["messages"]).to eq([
        { "role" => "user",      "content" => "first question" },
        { "role" => "assistant", "content" => "first reply" },
        { "role" => "user",      "content" => "new turn" }
      ])
    end

    it "builds the same single-message body as before when history is empty" do
      expect(captured_body["messages"]).to eq([ { "role" => "user", "content" => "new turn" } ])
    end

    it "leaves the flattened transcript out of the final turn entirely" do
      history = [ { role: "assistant", content: "prior reply" } ]

      expect(captured_body(history: history)["messages"].last["content"]).to eq("new turn")
    end
  end
end
