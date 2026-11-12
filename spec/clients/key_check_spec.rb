require "rails_helper"

RSpec.describe "checking a key with a provider", :real_key_check do
  PROVIDERS = {
    ClaudeService => { key: "sk-ant-api03-SecretKeyValue", url: "https://api.anthropic.com/v1/models",
                       headers: { "x-api-key" => "sk-ant-api03-SecretKeyValue", "anthropic-version" => "2023-06-01" },
                       rejection: [ 401, "anthropic_401_invalid_key.json" ] },
    GeminiService => { key: "AIzaSecretKeyValue", url: "https://generativelanguage.googleapis.com/v1beta/models",
                       headers: { "x-goog-api-key" => "AIzaSecretKeyValue" },
                       rejection: [ 400, "gemini_400_api_key_invalid.json" ] },
    OpenaiService => { key: "sk-proj-SecretKeyValue", url: "https://api.openai.com/v1/models",
                       headers: { "authorization" => "Bearer sk-proj-SecretKeyValue" },
                       rejection: [ 401, "openai_401_invalid_key.json" ] }
  }.freeze

  def logged
    io = StringIO.new
    sink = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(sink)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  PROVIDERS.each do |service_class, facts|
    describe service_class do
      let(:service) { service_class.new(facts[:key]) }

      it "asks its list-models endpoint once, with the key in a header and never in the URL" do
        requests = stub_key_check(service_class)

        expect(service.check_key).to eq(:accepted)
        expect(service_class::MODELS_URL).to eq(facts[:url])
        expect(requests.size).to eq(1)
        expect(requests.first.method).to eq(:get)
        expect(requests.first.url.to_s).to eq(facts[:url])
        expect(requests.first.request_headers.to_h).to include(facts[:headers])
      end

      it "sends the headers its generation calls send" do
        generation = service.instance_variable_get(:@conn).headers.to_h.except("content-type", "User-Agent")

        expect(service.send(:key_check_connection).headers.to_h.except("User-Agent")).to eq(generation)
      end

      it "reads the provider's bad-key answer as rejected" do
        status, body = facts[:rejection]
        stub_key_check(service_class, status: status, body: key_check_fixture(body))

        expect(service.check_key).to eq(:rejected)
      end

      it "reads a 401 as rejected whatever the body says" do
        stub_key_check(service_class, status: 401, body: "<html>no</html>")

        expect(service.check_key).to eq(:rejected)
      end

      it "reads a 403 as refused, which is not a rejection" do
        stub_key_check(service_class, status: 403, body: key_check_fixture("gemini_403_permission_denied.json"))

        expect(service.check_key).to eq(:refused)
      end

      [ 400, 404, 429, 500, 502, 503, 529 ].each do |status|
        it "reads a #{status} as unanswered after one request" do
          requests = stub_key_check(service_class, status: status, body: "{}")

          expect(service.check_key).to eq(:unanswered)
          expect(requests.size).to eq(1)
        end
      end

      [ Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError ].each do |error|
        it "reads a #{error.name.demodulize} as unanswered after one request" do
          requests = stub_key_check(service_class, error: error)

          expect(service.check_key).to eq(:unanswered)
          expect(requests.size).to eq(1)
        end
      end

      it "waits a few seconds at most and has no retry middleware" do
        connection = service.send(:key_check_connection)

        expect(connection.options.open_timeout).to eq(CallProfiles::KEY_CHECK_OPEN_TIMEOUT)
        expect(connection.options.timeout).to eq(CallProfiles::KEY_CHECK_READ_TIMEOUT)
        expect(connection.builder.handlers).not_to include(Faraday::Retry::Middleware)
      end

      it "logs the result and status, and neither the key nor the provider's body" do
        status, body = facts[:rejection]
        stub_key_check(service_class, status: status, body: key_check_fixture(body))

        output = logged { service.check_key }

        expect(output).to include("[key_check] provider=#{service_class.provider_key} result=rejected status=#{status}")
        expect(output).not_to include(facts[:key])
        expect(output).not_to match(/Incorrect API key|invalid x-api-key|API key not valid/)
      end

      it "logs an unanswered check by error class, without the error's message" do
        stub_key_check(service_class, error: Faraday::TimeoutError)

        output = logged { service.check_key }

        expect(output).to include("[key_check] provider=#{service_class.provider_key} result=unanswered error=Faraday::TimeoutError")
        expect(output).not_to include("boom")
      end

      it "reads an error it has no rule for as unanswered, logging its class and never its message" do
        stub_key_check(service_class, error: ArgumentError)

        output = logged { expect(service.check_key).to eq(:unanswered) }

        expect(output).to include("[key_check] provider=#{service_class.provider_key} result=unanswered error=ArgumentError")
        expect(output).not_to include("boom")
      end

      it "logs a transport failure at info and an unexpected error class at error level" do
        levels = Hash.new { |hash, level| hash[level] = [] }
        %i[info error].each { |level| allow(Rails.logger).to receive(level) { |message| levels[level] << message } }

        [ Faraday::ConnectionFailed, Timeout::Error, NoMethodError ].each do |error|
          stub_key_check(service_class, error: error)
          expect(service.check_key).to eq(:unanswered)
        end

        prefix = "[key_check] provider=#{service_class.provider_key} result=unanswered error="
        expect(levels[:info].grep(/key_check/)).to eq([ "#{prefix}Faraday::ConnectionFailed", "#{prefix}Timeout::Error" ])
        expect(levels[:error].grep(/key_check/)).to eq([ "#{prefix}NoMethodError" ])
      end

      it "logs an error raised while reading the reply at error level too" do
        stub_key_check(service_class)
        allow(service).to receive(:key_check_result).and_raise(NoMethodError, "undefined method for secret")
        allow(Rails.logger).to receive(:error)

        expect(service.check_key).to eq(:unanswered)
        expect(Rails.logger).to have_received(:error).with("[key_check] provider=#{service_class.provider_key} result=unanswered error=NoMethodError")
      end

      it "gives up once the whole check has run past its total bound, however the reply arrives" do
        stub_const("CallProfiles::KEY_CHECK_TOTAL_SECONDS", 0.05)
        stub_key_check(service_class, delay: 1)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        output = logged { expect(service.check_key).to eq(:unanswered) }

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.9
        expect(output).to match(/\[key_check\] provider=#{service_class.provider_key} result=unanswered error=\S*Timeout/)
      end

      it "is reached through AiService.check_key by its provider key" do
        stub_key_check(service_class, status: 403)

        expect(AiService.check_key(service_class.provider_key, facts[:key])).to eq(:refused)
      end

      it "writes no usage row" do
        stub_key_check(service_class)

        expect { service.check_key }.not_to change(ApiUsage, :count)
      end
    end
  end

  it "bounds the whole check by its connect and read timeouts together, well under a page's patience" do
    expect(CallProfiles::KEY_CHECK_TOTAL_SECONDS).to eq(CallProfiles::KEY_CHECK_OPEN_TIMEOUT + CallProfiles::KEY_CHECK_READ_TIMEOUT)
    expect(CallProfiles::KEY_CHECK_TOTAL_SECONDS).to be <= 10
    expect(CallProfiles::KEY_CHECK_READ_TIMEOUT).to be < CallProfiles::READ_TIMEOUT
  end

  it "returns only the results it names" do
    results = [ [ 200, "{}" ], [ 401, "{}" ], [ 403, "{}" ], [ 500, "{}" ] ].map do |status, body|
      stub_key_check(OpenaiService, status: status, body: body)
      OpenaiService.new("sk-proj-SecretKeyValue").check_key
    end

    expect(results).to eq(AiService::KEY_CHECK_RESULTS)
  end

  it "reads Gemini's 400 as unanswered when the body does not name the key" do
    stub_key_check(GeminiService, status: 400, body: { error: { status: "INVALID_ARGUMENT" } }.to_json)

    expect(GeminiService.new("AIzaSecretKeyValue").check_key).to eq(:unanswered)
  end

  describe "AiService.check_key" do
    it "applies the gate AiService.for applies, refusing the fake provider outside a local environment" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect { AiService.check_key("fake", "fake-test-key") }.to raise_error(SetupError, /fake/)
    end

    it "refuses a provider key the registry does not hold" do
      expect { AiService.check_key("nobody", "sk-ant-api03-SecretKeyValue") }.to raise_error(SetupError)
    end

    it "names neither the key nor its length in the error it raises" do
      expect { AiService.check_key("nobody", "sk-ant-api03-SecretKeyValue") }
        .to raise_error(SetupError) { |error| expect(error.message).not_to include("SecretKeyValue") }
    end

    it "answers for the fake provider in a local environment" do
      expect(AiService.check_key("fake", "fake-test-key")).to eq(:accepted)
    end
  end

  it "answers for the fake provider without building a connection" do
    service = FakeService.new("fake-test-key")
    allow(Faraday).to receive(:new).and_call_original

    expect(service.check_key).to eq(:accepted)
    expect(Faraday).not_to have_received(:new)
  end
end

RSpec.describe "the key check in every other spec" do
  it "answers accepted without building a connection" do
    expect_any_instance_of(ClaudeService).not_to receive(:key_check_connection)

    expect(ClaudeService.new("sk-ant-api03-SecretKeyValue").check_key).to eq(:accepted)
  end
end
