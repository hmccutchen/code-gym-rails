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
      expect(result).to eq(text: "hello", input_tokens: 8, output_tokens: 12)
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
end
