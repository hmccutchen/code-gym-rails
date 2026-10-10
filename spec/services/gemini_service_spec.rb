require "rails_helper"

RSpec.describe GeminiService do
  let(:service) { described_class.new("AIzaTestKey") }

  # Real retry configuration on a Faraday test adapter; `responses` is a queue of [status, body] pairs.
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

  it "raises InvalidResponseError, which callers rescue, when a successful response body is not JSON" do
    service.instance_variable_set(:@conn, stubbed_connection([ [ 200, "<html>Bad gateway</html>" ] ]))

    expect { service.send(:call, system: "sys", prompt: "p") }
      .to raise_error(AiService::InvalidResponseError, /Gemini returned an unreadable response/)
  end

  # A cut-off JSON body can carry an answer (a judge's blind solve), so only its size is logged.
  it "withholds a cut-off JSON body from the log and still logs a non-JSON one" do
    logged = []
    allow(Rails.logger).to receive(:error) { |message| logged << message }

    expect { service.send(:unreadable_envelope!, '{"text":"{\\"better\\":\\"b\\"', "Gemini") }
      .to raise_error(AiService::InvalidResponseError)
    expect { service.send(:unreadable_envelope!, '"{\\"better\\":\\"b\\"', "Gemini") }
      .to raise_error(AiService::InvalidResponseError)
    expect { service.send(:unreadable_envelope!, "<html>Bad gateway</html>", "Gemini") }
      .to raise_error(AiService::InvalidResponseError)

    expect(logged.first(2)).to all(include("withheld").and(satisfy { |line| !line.include?("better") }))
    expect(logged.last).to include("Bad gateway")
  end

  it "raises InvalidResponseError rather than a TypeError when a successful response body is not a JSON object" do
    service.instance_variable_set(:@conn, stubbed_connection([ [ 200, "[]" ] ]))

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
    # Records what each attempt saw, so assertions cover the request that reached the adapter.
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

    # A timed-out generation was very likely finished and billed, so retrying pays for it again.
    it "does not retry a generation that times out" do
      attempts = []
      service.instance_variable_set(:@conn, recording_connection(attempts))

      expect {
        service.send(:call, system: "sys", prompt: "p", read_timeout: AiService::GENERATION_READ_TIMEOUT)
      }.to raise_error(AiService::TimeoutError, /Network error calling Gemini/)

      expect(attempts.size).to eq(1)
    end

    # A timed-out grade was usually billed; its budget exceeds READ_TIMEOUT, so the guard treats it as long_running.
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

    it "raises RateLimitError after three attempts (two retries) on a persistent 429" do
      responses = [ [ 429, "" ], [ 429, "" ], [ 429, "" ], [ 429, "" ] ]
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::RateLimitError)
      expect(responses.size).to eq(1)
    end

    it "raises AuthenticationError immediately on a 401, without retrying" do
      responses = [ [ 401, { "error" => { "message" => "API key not valid" } }.to_json ], [ 200, success_body ] ]
      service.instance_variable_set(:@conn, stubbed_connection(responses))

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::AuthenticationError, "Google rejected your API key or its permissions. Check it in Settings.")
      expect(responses.size).to eq(1)
    end

    [ 401, 403 ].each do |status|
      it "keeps credentials out of logs and errors on HTTP #{status}" do
        body = { error: { message: "API key AIzaTestKeyFragment is not valid" } }.to_json
        service.instance_variable_set(:@conn, stubbed_connection([ [ status, body ] ]))
        allow(Rails.logger).to receive(:error)

        expect { service.send(:call, system: "sys", prompt: "prompt") }
          .to raise_error(AiService::AuthenticationError, /\AGoogle rejected your API key/) { |error|
            expect(error.http_status).to eq(status)
            expect(error.message).not_to include("AIza")
          }
        expect(Rails.logger).not_to have_received(:error).with(/AIza/)
      end
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
      expect(result).to eq(text: "hello", input_tokens: 8, output_tokens: 12, truncated: false, http_status: 200,
                           model: GeminiService::DEFAULT_ROUTE[:model], cache_read_tokens: 0, cache_write_tokens: 0)
    end

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

    it "omits generation_config entirely when no max_tokens override is given, so uncapped generation keeps full thinking" do
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
      }.to raise_error(AiService::Error, /Gemini API error 503/) { |error| expect(error.http_status).to eq(503) }
    end

    it "surfaces the provider's own error message when the body includes one" do
      body = { "error" => { "code" => 400, "message" => "Invalid JSON payload received.", "status" => "INVALID_ARGUMENT" } }.to_json
      fake_response = instance_double(Faraday::Response, success?: false, status: 400, body: body)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error, "Invalid JSON payload received.")
    end

    def quota_fixture(name) = Rails.root.join("spec/fixtures/provider_errors", name).read

    it "names the quota and the delay from a 429 body, and never its message" do
      service.instance_variable_set(:@conn, stubbed_connection([ [ 429, quota_fixture("gemini_429_daily.json") ] ]))

      expect { service.send(:call, system: "sys", prompt: "prompt", single_attempt: true) }
        .to raise_error(AiService::RateLimitError) { |e|
          expect(e.quota_id).to eq("GenerateRequestsPerDayPerProjectPerModel-FreeTier")
          expect(e.retry_after).to eq(39)
          expect(e.message).not_to include("quota")
        }
    end

    it "prefers the daily quota when a 429 lists it beside a per-minute one" do
      body = JSON.parse(quota_fixture("gemini_429_minute.json"))
      failure = body["error"]["details"].find { |d| d["@type"].end_with?("QuotaFailure") }
      failure["violations"] << { "quotaMetric" => "generativelanguage.googleapis.com/generate_content_free_tier_requests",
                                 "quotaId" => "GenerateRequestsPerDayPerProjectPerModel-FreeTier", "quotaValue" => "20" }
      service.instance_variable_set(:@conn, stubbed_connection([ [ 429, body.to_json ] ]))

      expect { service.send(:call, system: "sys", prompt: "prompt", single_attempt: true) }
        .to raise_error(AiService::RateLimitError) { |e| expect(e.quota_id).to eq("GenerateRequestsPerDayPerProjectPerModel-FreeTier") }
    end

    it "falls back to the status when the error envelope is null" do
      allow(Rails.logger).to receive(:error)
      service.instance_variable_set(:@conn, stubbed_connection([ [ 429, { "error" => nil }.to_json ] ]))
      expect { service.send(:call, system: "sys", prompt: "prompt", single_attempt: true) }
        .to raise_error(AiService::RateLimitError) { |e| expect(e.quota_id).to be_nil }

      service.instance_variable_set(:@conn, stubbed_connection([ [ 400, { "error" => nil }.to_json ] ]))
      expect { service.send(:call, system: "sys", prompt: "prompt") }
        .to raise_error(AiService::Error, /Gemini API error 400/) { |e| expect(e).not_to be_a(AiService::AuthenticationError) }
    end

    it "reads a 400 API_KEY_INVALID as a rejected key without logging the body" do
      allow(Rails.logger).to receive(:error)
      service.instance_variable_set(:@conn, stubbed_connection([ [ 400, quota_fixture("gemini_400_api_key_invalid.json") ] ]))

      expect { service.send(:call, system: "sys", prompt: "prompt") }
        .to raise_error(AiService::AuthenticationError, /\AGoogle rejected your API key/) { |e| expect(e.http_status).to eq(400) }
      expect(Rails.logger).not_to have_received(:error).with(/API key not valid/)
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

  describe "#call with history" do
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

  describe "#call with response_schema" do
    include AuthHelpers

    let(:schema) { { "type" => "object", "properties" => { "status" => { "type" => "string" } }, "required" => [ "status" ], "additionalProperties" => false } }

    it "asks for a JSON reply held to the schema" do
      body = captured_body(response_schema: schema, max_tokens: 100, purpose: "judge_section")

      expect(body["response_format"]).to eq("type" => "text", "mime_type" => "application/json", "schema" => schema)
    end

    it "keeps the cap and minimal thinking beside the schema" do
      body = captured_body(response_schema: schema, max_tokens: 100, purpose: "judge_section")

      expect(body["generation_config"]).to eq("max_output_tokens" => 100, "thinking_level" => GeminiService::MINIMAL_THINKING_LEVEL)
    end

    it "sends no response format when no schema is given" do
      expect(captured_body(max_tokens: 100, purpose: "judge_section")).not_to have_key("response_format")
    end

    it "holds a judge reply to the kind's verdict schema" do
      kind = ExerciseSection::DesignComparison
      body = nil
      service.instance_variable_set(:@conn, Faraday.new do |f|
        f.adapter :test do |stub|
          stub.post(GeminiService::API_URL) do |env|
            body = JSON.parse(env.body)
            [ 200, {}, success_body(text: { status: "keep", better: "a" }.to_json) ]
          end
        end
      end)

      verdict = service.judge_section(create_user_with_key, kind, { "title" => "t", "scenario" => "s", "question" => "q" },
                                      rung: "senior", locked: false)

      expect(body["response_format"]["schema"]).to eq(JSON.parse(JudgeVerdict.schema_for(kind).to_json))
      expect(verdict.status).to eq(:keep)
    end
  end
end
