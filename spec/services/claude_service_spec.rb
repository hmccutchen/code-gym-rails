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
  end

  describe "retry/backoff" do
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
      expect(result).to eq(text: "hello", input_tokens: 10, output_tokens: 20)
    end

    it "requests an output budget large enough for a full three-section review" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200, body: success_body)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |_url, body|
        expect(JSON.parse(body)["max_tokens"]).to eq(ClaudeService::MAX_TOKENS)
        fake_response
      end

      service.send(:call, system: "sys", prompt: "prompt text")
      expect(ClaudeService::MAX_TOKENS).to be >= 8_000
    end

    it "raises TruncatedResponseError when the model stopped at the output cap" do
      body = {
        "content"     => [ { "type" => "text", "text" => '{"code_review": {"correct": ["half a sen' } ],
        "stop_reason" => "max_tokens",
        "usage"       => { "input_tokens" => 10, "output_tokens" => 2500 }
      }.to_json
      fake_response = instance_double(Faraday::Response, success?: true, status: 200, body: body)
      service.instance_variable_set(:@conn, instance_double(Faraday::Connection, post: fake_response))

      expect {
        service.send(:call, system: "sys", prompt: "prompt text")
      }.to raise_error(AiService::TruncatedResponseError, /output limit/i)
    end

    it "does not raise for a normal end_turn stop reason" do
      body = {
        "content"     => [ { "type" => "text", "text" => "hello" } ],
        "stop_reason" => "end_turn",
        "usage"       => { "input_tokens" => 10, "output_tokens" => 20 }
      }.to_json
      fake_response = instance_double(Faraday::Response, success?: true, status: 200, body: body)
      service.instance_variable_set(:@conn, instance_double(Faraday::Connection, post: fake_response))

      expect(service.send(:call, system: "sys", prompt: "prompt text")[:text]).to eq("hello")
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
  end
end
