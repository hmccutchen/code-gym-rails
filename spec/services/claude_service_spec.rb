require "rails_helper"

RSpec.describe ClaudeService do
  let(:service) { described_class.new("sk-ant-test") }

  # Real retry configuration on a Faraday test adapter; `responses` is a queue of [status, body] pairs.
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

  # A bare JSON::ParserError would escape every caller's AiService::Error rescue.
  it "raises InvalidResponseError when a successful response body is not JSON" do
    service.instance_variable_set(:@conn, stubbed_connection([ [ 200, "<html>Bad gateway</html>" ] ]))

    expect { service.send(:call, system: "sys", prompt: "p") }
      .to raise_error(AiService::InvalidResponseError, /Claude returned an unreadable response/)
  end

  # A cut-off JSON body can carry an answer (a judge's blind solve), so only its size is logged.
  it "withholds a cut-off JSON body from the log and still logs a non-JSON one" do
    logged = []
    allow(Rails.logger).to receive(:error) { |message| logged << message }

    expect { service.send(:unreadable_envelope!, '{"text":"{\\"better\\":\\"b\\"', "Claude") }
      .to raise_error(AiService::InvalidResponseError)
    expect { service.send(:unreadable_envelope!, '"{\\"better\\":\\"b\\"', "Claude") }
      .to raise_error(AiService::InvalidResponseError)
    expect { service.send(:unreadable_envelope!, "<html>Bad gateway</html>", "Claude") }
      .to raise_error(AiService::InvalidResponseError)

    expect(logged.first(2)).to all(include("withheld").and(satisfy { |line| !line.include?("better") }))
    expect(logged.last).to include("Bad gateway")
  end

  # Wrong-shape JSON would otherwise escape every AiService::Error rescue as a TypeError.
  it "raises InvalidResponseError when a successful response body is not a JSON object" do
    service.instance_variable_set(:@conn, stubbed_connection([ [ 200, "[]" ] ]))

    expect { service.send(:call, system: "sys", prompt: "p") }
      .to raise_error(AiService::InvalidResponseError, /Claude returned an unreadable response/)
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
    # Records what each attempt saw, so assertions cover the request that reached the adapter.
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

    # A timed-out generation was very likely finished and billed, so retrying pays for it again.
    it "does not retry a generation that times out" do
      attempts = []
      service.instance_variable_set(:@conn, recording_connection(attempts))

      expect {
        service.send(:call, system: "sys", prompt: "p", read_timeout: AiService::GENERATION_READ_TIMEOUT)
      }.to raise_error(AiService::TimeoutError, /Network error calling Claude/)

      expect(attempts.size).to eq(1)
    end

    # A timed-out grade was usually billed; its budget exceeds READ_TIMEOUT, so the guard treats it as long_running.
    it "does not retry a grading call that times out" do
      attempts = []
      service.instance_variable_set(:@conn, recording_connection(attempts))

      expect {
        service.send(:call, system: "sys", prompt: "p", read_timeout: AiService::REVIEW_READ_TIMEOUT)
      }.to raise_error(AiService::TimeoutError, /Network error calling Claude/)

      expect(attempts).to eq([ AiService::REVIEW_READ_TIMEOUT ])
    end

    it "still retries a short call that times out" do
      attempts = []
      service.instance_variable_set(:@conn, recording_connection(attempts))

      expect {
        service.send(:call, system: "sys", prompt: "p")
      }.to raise_error(AiService::TimeoutError, /Network error calling Claude/)

      expect(attempts.size).to eq(ClaudeService::RETRY_OPTIONS[:max] + 1)
    end
  end

  describe "retry/backoff" do
    # The backoff sleeps for real; these assert attempt counts and errors, never timing.
    before { allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep) }

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
      }.to raise_error(AiService::AuthenticationError, "Anthropic rejected your API key or its permissions. Check it in Settings.")
      # 401 is not in retry_statuses, so the second stubbed response is never consumed.
      expect(responses.size).to eq(1)
    end

    [ 401, 403 ].each do |status|
      it "keeps credentials out of logs and errors on HTTP #{status}" do
        body = { error: { message: "API key sk-ant-TestKeyFragment is not valid" } }.to_json
        service.instance_variable_set(:@conn, stubbed_connection([ [ status, body ] ]))
        allow(Rails.logger).to receive(:error)

        expect { service.send(:call, system: "sys", prompt: "prompt") }
          .to raise_error(AiService::AuthenticationError, /\AAnthropic rejected your API key/) { |error|
            expect(error.http_status).to eq(status)
            expect(error.message).not_to include("sk-ant-")
          }
        expect(Rails.logger).not_to have_received(:error).with(/sk-ant-/)
      end
    end

    describe "a single-attempt call" do
      it "makes one request for a 429 and raises" do
        responses = [ [ 429, "" ], [ 429, "" ], [ 429, "" ] ]
        service.instance_variable_set(:@conn, stubbed_connection(responses))

        expect { service.send(:call, system: "sys", prompt: "p", single_attempt: true) }.to raise_error(AiService::RateLimitError)
        expect(responses.size).to eq(2)
      end

      it "makes one request for a timeout and raises" do
        attempts = 0
        conn = Faraday.new do |f|
          f.request :retry, ClaudeService::RETRY_OPTIONS
          f.adapter(:test) { |stub| stub.post(ClaudeService::API_URL) { attempts += 1; raise Faraday::TimeoutError } }
        end
        service.instance_variable_set(:@conn, conn)

        expect { service.send(:call, system: "sys", prompt: "p", single_attempt: true) }.to raise_error(AiService::TimeoutError)
        expect(attempts).to eq(1)
      end

      it "leaves an unflagged call on every retry attempt" do
        attempts = 0
        conn = Faraday.new do |f|
          f.request :retry, ClaudeService::RETRY_OPTIONS
          f.adapter(:test) { |stub| stub.post(ClaudeService::API_URL) { attempts += 1; raise Faraday::TimeoutError } }
        end
        service.instance_variable_set(:@conn, conn)

        expect { service.send(:call, system: "sys", prompt: "p") }.to raise_error(AiService::TimeoutError)
        expect(attempts).to eq(AiService::RETRY_MAX + 1)
      end
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
        expect(parsed["model"]).to eq(ClaudeService::DEFAULT_ROUTE[:model])
        expect(parsed["system"]).to eq("sys")
        expect(parsed["messages"]).to eq([ { "role" => "user", "content" => "prompt text" } ])
        fake_response
      end

      result = service.send(:call, system: "sys", prompt: "prompt text")
      expect(result).to eq(text: "hello", input_tokens: 10, output_tokens: 20, truncated: false, refusal: nil,
                           model: ClaudeService::DEFAULT_ROUTE[:model], cache_read_tokens: 0, cache_write_tokens: 0,
                           http_status: 200)
    end

    # input_tokens excludes cached tokens, and reads and writes are billed at different rates.
    it "reports cache reads and writes separately from input tokens" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "content" => [ { "type" => "text", "text" => "hello" } ],
          "usage"   => { "input_tokens" => 10, "output_tokens" => 20,
                         "cache_read_input_tokens" => 900, "cache_creation_input_tokens" => 1_100 }
        }.to_json)
      service.instance_variable_set(:@conn, instance_double(Faraday::Connection, post: fake_response))

      result = service.send(:call, system: "sys", prompt: "p")

      expect(result).to include(input_tokens: 10, cache_read_tokens: 900, cache_write_tokens: 1_100)
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

    # A three-section review overran the old 2500-token budget and came back truncated.
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

    # max_tokens caps thinking and reply together; the thinking-off setting is a per-model fact.
    describe "thinking-off for a capped call" do
      def capped_body(model)
        body = nil
        fake_conn = instance_double(Faraday::Connection)
        service.instance_variable_set(:@conn, fake_conn)
        allow(service).to receive(:route_for).and_return({ model: model })
        allow(fake_conn).to receive(:post) do |_url, raw|
          body = JSON.parse(raw)
          instance_double(Faraday::Response, success?: true, status: 200, body: success_body)
        end
        service.send(:call, system: "sys", prompt: "p", max_tokens: 100)
        body
      end

      it "sends between_tools on Sonnet 5.5" do
        expect(capped_body("claude-sonnet-5-5")["thinking"]).to eq("type" => "between_tools")
      end

      it "sends disabled on Haiku 4.5" do
        expect(capped_body("claude-haiku-4-5")["thinking"]).to eq("type" => "disabled")
      end

      # An AiService::Error, so the controllers' rescue shows a try-again message instead of an error page.
      it "refuses a capped call on a model with no thinking-off setting, before sending, as an AiService error" do
        posts = 0
        conn = Faraday.new { |f| f.adapter(:test) { |stub| stub.post(ClaudeService::API_URL) { posts += 1; [ 200, {}, success_body ] } } }
        service.instance_variable_set(:@conn, conn)
        allow(service).to receive(:route_for).and_return({ model: "claude-opus-5-5" })

        expect { service.send(:call, system: "sys", prompt: "p", max_tokens: 100) }
          .to raise_error(AiService::UnsupportedRouteError, /claude-opus-5-5/)
        expect(posts).to eq(0)
        expect(AiService::UnsupportedRouteError).to be < AiService::Error
      end
    end

    it "reports truncation when the model stopped at the output cap" do
      body = {
        "content"     => [ { "type" => "text", "text" => '{"code_review": {"correct": ["half a sen' } ],
        "stop_reason" => "max_tokens",
        "usage"       => { "input_tokens" => 10, "output_tokens" => 2500 }
      }.to_json
      fake_response = instance_double(Faraday::Response, success?: true, status: 200, body: body)
      service.instance_variable_set(:@conn, instance_double(Faraday::Connection, post: fake_response))

      # Reported as data: AiService#call_and_log records the billed usage before the failure propagates.
      expect(service.send(:call, system: "sys", prompt: "prompt text")[:truncated]).to be(true)
    end

    # Left unnamed, a refusal surfaces as an empty-response parse error that hides the safety classifier.
    it "reports a refusal and its category as data, with the billed usage, rather than raising" do
      body = {
        "content"      => [],
        "stop_reason"  => "refusal",
        "stop_details" => { "type" => "refusal", "category" => "cyber", "explanation" => "declined" },
        "usage"        => { "input_tokens" => 10, "output_tokens" => 0 }
      }.to_json
      fake_response = instance_double(Faraday::Response, success?: true, status: 200, body: body)
      service.instance_variable_set(:@conn, instance_double(Faraday::Connection, post: fake_response))

      # Reported as data so AiService#call_and_log records the billed usage before it raises.
      result = service.send(:call, system: "sys", prompt: "prompt text")

      expect(result[:refusal]).to eq("cyber")
      expect(result[:input_tokens]).to eq(10)
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
      }.to raise_error(AiService::Error, /Claude API error 500/) { |error| expect(error.http_status).to eq(500) }
    end

    it "surfaces the provider's own error message when the body includes one" do
      body = { "type" => "error", "error" => { "type" => "invalid_request_error", "message" => "messages: at least one message is required" } }.to_json
      fake_response = instance_double(Faraday::Response, success?: false, status: 400, body: body)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error, "messages: at least one message is required")
    end

    # Per platform.claude.com's errors and rate-limits pages, none of these is a rate limit.
    {
      "a credit-balance 400"   => [ 400, { "type" => "invalid_request_error", "message" => "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits." } ],
      "a spend-limit 400"      => [ 400, { "type" => "invalid_request_error", "message" => "You have reached your specified API usage limits. You will regain access on 2026-11-01 at 00:00 UTC." } ],
      "a 402 billing_error"    => [ 402, { "type" => "billing_error", "message" => "There is an issue with your billing." } ],
      "a tier spend-cap 429"   => [ 429, { "type" => "rate_limit_error", "message" => "You have reached your API usage limits.", "details" => { "error_code" => "enforced_spend_limit_reached" } } ]
    }.each do |label, (status, error)|
      it "reads #{label} as out of credit, not a rate limit" do
        allow(Rails.logger).to receive(:warn)
        service.instance_variable_set(:@conn, stubbed_connection([ [ status, { "type" => "error", "error" => error }.to_json ] ]))

        expect { service.send(:call, system: "sys", prompt: "prompt", single_attempt: true) }
          .to raise_error(AiService::BillingError) { |e|
            expect(e.http_status).to eq(status)
            expect(e.message).not_to include("credit balance", "regain access")
          }
      end
    end

    it "names the exhausted limit family and the wait on a 429" do
      headers = { "retry-after" => "17", "anthropic-ratelimit-requests-remaining" => "40",
                  "anthropic-ratelimit-input-tokens-remaining" => "0" }
      conn = Faraday.new do |f|
        f.adapter(:test) { |stub| stub.post(ClaudeService::API_URL) { [ 429, headers, { "type" => "error", "error" => { "type" => "rate_limit_error", "message" => "x" } }.to_json ] } }
      end
      service.instance_variable_set(:@conn, conn)

      expect { service.send(:call, system: "sys", prompt: "prompt") }
        .to raise_error(AiService::RateLimitError) { |e|
          expect(e.quota_id).to eq("anthropic-ratelimit-input-tokens")
          expect(e.retry_after).to eq(17)
        }
    end

    it "falls back to the status when the error envelope is null" do
      allow(Rails.logger).to receive(:warn)
      service.instance_variable_set(:@conn, stubbed_connection([ [ 429, { "type" => "error", "error" => nil }.to_json ] ]))
      expect { service.send(:call, system: "sys", prompt: "prompt", single_attempt: true) }
        .to raise_error(AiService::RateLimitError) { |e| expect(e.quota_id).to eq("rate_limit_error") }

      service.instance_variable_set(:@conn, stubbed_connection([ [ 400, { "type" => "error", "error" => nil }.to_json ] ]))
      expect { service.send(:call, system: "sys", prompt: "prompt") }
        .to raise_error(AiService::Error) { |e| expect(e).not_to be_a(AiService::BillingError) }
    end

    it "falls back to the error type as the quota id when no family reads zero" do
      conn = Faraday.new do |f|
        f.adapter(:test) { |stub| stub.post(ClaudeService::API_URL) { [ 529, {}, { "type" => "error", "error" => { "type" => "overloaded_error", "message" => "x" } }.to_json ] } }
      end
      service.instance_variable_set(:@conn, conn)

      expect { service.send(:call, system: "sys", prompt: "prompt") }
        .to raise_error(AiService::RateLimitError) { |e| expect(e.quota_id).to eq("overloaded_error") }
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

  describe "#call with response_schema" do
    let(:schema) { { "type" => "object", "properties" => { "status" => { "type" => "string" } }, "required" => [ "status" ], "additionalProperties" => false } }

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
      service.send(:call, system: "sys", prompt: "p", **kwargs)
      body
    end

    it "constrains the reply to the schema and sends no prefill" do
      body = captured_body(response_schema: schema, max_tokens: 100, purpose: "judge_section")

      expect(body["output_config"]).to eq("effort" => "high", "format" => { "type" => "json_schema", "schema" => schema })
      expect(body["messages"].last["role"]).to eq("user")
    end

    it "sends the schema beside a route's effort" do
      body = captured_body(response_schema: schema, purpose: "generate_exercise")

      expect(body["output_config"]).to eq("effort" => "medium", "format" => { "type" => "json_schema", "schema" => schema })
    end

    it "sends no format when no schema is given" do
      expect(captured_body(purpose: "judge_section")["output_config"]).not_to have_key("format")
    end
  end
end
