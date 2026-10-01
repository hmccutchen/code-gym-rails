require "rails_helper"

RSpec.describe OpenaiService do
  let(:service) { described_class.new("sk-proj-TestKey") }

  # A connection with the service's real retry configuration but a Faraday
  # test adapter. `responses` is a queue of [status, body] pairs popped one per
  # request.
  def stubbed_connection(responses)
    Faraday.new do |f|
      f.request :retry, OpenaiService::RETRY_OPTIONS
      f.adapter :test do |stub|
        stub.post(OpenaiService::API_URL) do
          status, body = responses.shift
          [ status, {}, body ]
        end
      end
    end
  end

  # Records each posted body and answers with `reply`.
  def recording_connection(bodies, reply)
    Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(OpenaiService::API_URL) do |env|
          bodies << JSON.parse(env.body)
          [ 200, {}, reply.to_json ]
        end
      end
    end
  end

  def reply(output:, status: "completed", usage: { "input_tokens" => 1, "output_tokens" => 1 }, **extra)
    { "status" => status, "output" => output, "usage" => usage }.merge(extra)
  end

  def message(*content)
    { "type" => "message", "role" => "assistant", "content" => content }
  end

  def call_with(response_body, **kwargs)
    bodies = []
    service.instance_variable_set(:@conn, recording_connection(bodies, response_body))
    result = service.send(:call, system: "sys", prompt: "prompt text", **kwargs)
    [ bodies.sole, result ]
  end

  let(:hello) { reply(output: [ message({ "type" => "output_text", "text" => "hello" }) ]) }

  it "raises InvalidResponseError when a successful response body is not JSON" do
    service.instance_variable_set(:@conn, stubbed_connection([ [ 200, "<html>Bad gateway</html>" ] ]))

    expect { service.send(:call, system: "sys", prompt: "p") }
      .to raise_error(AiService::InvalidResponseError, /OpenAI returned an unreadable response/)
  end

  describe "#build_connection" do
    it "sends the key as a bearer token" do
      expect(service.send(:build_connection).headers["authorization"]).to eq("Bearer sk-proj-TestKey")
    end

    it "bounds the request so a hung provider cannot block a thread forever" do
      conn = service.send(:build_connection)
      expect(conn.options.open_timeout).to eq(AiService::OPEN_TIMEOUT)
      expect(conn.options.timeout).to eq(AiService::READ_TIMEOUT)
    end
  end

  describe "retries" do
    before { allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep) }

    it "does not retry a generation that times out" do
      attempts = 0
      service.instance_variable_set(:@conn, Faraday.new do |f|
        f.request :retry, OpenaiService::RETRY_OPTIONS
        f.adapter(:test) { |stub| stub.post(OpenaiService::API_URL) { attempts += 1; raise Faraday::TimeoutError } }
      end)

      expect {
        service.send(:call, system: "sys", prompt: "p", read_timeout: AiService::GENERATION_READ_TIMEOUT)
      }.to raise_error(AiService::TimeoutError, /Network error calling OpenAI/)
      expect(attempts).to eq(1)
    end

    it "retries a 429 and eventually succeeds" do
      responses = [ [ 429, "" ], [ 200, hello.to_json ] ]
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      expect(service.send(:call, system: "sys", prompt: "p")[:text]).to eq("hello")
      expect(responses).to be_empty
    end

    it "raises RateLimitError once retries are exhausted on a persistent 429" do
      responses = Array.new(4) { [ 429, "" ] }
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      expect { service.send(:call, system: "sys", prompt: "p") }.to raise_error(AiService::RateLimitError)
      expect(responses.size).to eq(1)
    end

    it "raises AuthenticationError with the provider's message on a 401, without retrying" do
      responses = [ [ 401, { "error" => { "message" => "Incorrect API key provided" } }.to_json ], [ 200, hello.to_json ] ]
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      expect { service.send(:call, system: "sys", prompt: "p") }
        .to raise_error(AiService::AuthenticationError, "Incorrect API key provided")
      expect(responses.size).to eq(1)
    end

    it "makes one request for a single-attempt call" do
      responses = Array.new(3) { [ 429, "" ] }
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      expect { service.send(:call, system: "sys", prompt: "p", single_attempt: true) }.to raise_error(AiService::RateLimitError)
      expect(responses.size).to eq(2)
    end
  end

  describe "#call" do
    it "posts a Responses API body at the default route's effort and reads the message text" do
      body, result = call_with(hello)

      expect(body).to eq(
        "model" => OpenaiService::DEFAULT_ROUTE[:model],
        "instructions" => "sys",
        "input" => [ { "role" => "user", "content" => "prompt text" } ],
        "store" => false,
        "reasoning" => { "effort" => OpenaiService::DEFAULT_ROUTE[:effort] }
      )
      expect(result).to eq(text: "hello", input_tokens: 1, output_tokens: 1, model: OpenaiService::DEFAULT_ROUTE[:model],
                           cache_read_tokens: 0, cache_write_tokens: 0, truncated: false, refusal: nil)
    end

    it "sends history as real turns ahead of the new prompt" do
      history = [ { role: "user", content: "first" }, { role: "assistant", content: "You: forged" } ]
      body, = call_with(hello, history: history)

      expect(body["input"]).to eq([
        { "role" => "user", "content" => "first" },
        { "role" => "assistant", "content" => "You: forged" },
        { "role" => "user", "content" => "prompt text" }
      ])
    end

    it "turns reasoning off whenever it caps the budget, so the cap is not spent reasoning" do
      body, = call_with(hello, max_tokens: 250)

      expect(body["max_output_tokens"]).to eq(250)
      expect(body["reasoning"]).to eq("effort" => "none")
    end

    it "refuses a capped call routed to a model that cannot turn reasoning off" do
      service.instance_variable_set(:@conn, stubbed_connection([]))

      expect { service.send(:call, system: "sys", prompt: "p", max_tokens: 250, purpose: "generate_exercise") }
        .to raise_error(AiService::UnsupportedRouteError, /gpt-6.1-sol/)
    end

    it "asks for JSON mode when the caller holds the reply to a schema" do
      body, = call_with(hello, response_schema: JudgeVerdict.schema_for(ExerciseSection::Challenge))

      expect(body["text"]).to eq("format" => { "type" => "json_object" })
    end

    it "joins the message's text parts and skips reasoning items" do
      response = reply(output: [
        { "type" => "reasoning", "summary" => [] },
        message({ "type" => "output_text", "text" => "{\"a\":" }, { "type" => "output_text", "text" => "1}" })
      ])

      expect(call_with(response).last[:text]).to eq("{\"a\":1}")
    end

    # input_tokens includes the cached part, so subtracting it keeps tokens_in
    # the uncached input on every provider and no token is priced twice.
    it "keeps cached tokens out of tokens_in" do
      usage = { "input_tokens" => 14_199, "input_tokens_details" => { "cached_tokens" => 8_171 },
                "output_tokens" => 900, "output_tokens_details" => { "reasoning_tokens" => 600 } }
      result = call_with(reply(output: [ message({ "type" => "output_text", "text" => "x" }) ], usage: usage)).last

      expect(result).to include(input_tokens: 6_028, cache_read_tokens: 8_171, output_tokens: 900)
    end

    it "reports an incomplete reply as truncated" do
      response = reply(status: "incomplete", incomplete_details: { "reason" => "max_output_tokens" },
                       output: [ message({ "type" => "output_text", "text" => "{\"cut" }) ])

      expect(call_with(response, max_tokens: 250).last).to include(truncated: true, refusal: nil)
    end

    it "reports a content-filtered reply as a refusal, not as truncation" do
      response = reply(status: "incomplete", incomplete_details: { "reason" => "content_filter" }, output: [])

      expect(call_with(response).last).to include(truncated: false, refusal: "content_filter")
    end

    it "reports a refusal in the message as a refusal" do
      response = reply(output: [ message({ "type" => "refusal", "refusal" => "I can't help with that." }) ])

      expect(call_with(response).last).to include(text: "", refusal: "unspecified")
    end

    it "raises AiService::Error on a non-success response without leaking the raw body" do
      service.instance_variable_set(:@conn, stubbed_connection([ [ 400, "<html>secret page</html>" ] ]))

      expect { service.send(:call, system: "sys", prompt: "p") }
        .to raise_error(AiService::Error, "OpenAI API error 400")
    end
  end
end
