require "rails_helper"

RSpec.describe "provider transport" do
  before { allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep) }

  # Records the timeout and retry context each attempt reached the adapter with, then fails the attempt.
  def failing_service(service_class, attempts, error: Faraday::TimeoutError)
    service = service_class.new("test-key")
    service.instance_variable_set(:@conn, Faraday.new do |f|
      f.request :retry, service_class::RETRY_OPTIONS.merge(interval: 0, max_interval: 0)
      f.adapter :test do |stub|
        stub.post(service_class::API_URL) do |env|
          attempts << { timeout: env.request.timeout, **env.request.context.slice(:long_running, :single_attempt) }
          raise error, "boom"
        end
      end
    end)
    service
  end

  { ClaudeService => "Claude", GeminiService => "Gemini", OpenaiService => "OpenAI" }.each do |service_class, name|
    describe service_class do
      it "sends a default request with neither flag and retries its timeout" do
        attempts = []
        service = failing_service(service_class, attempts)

        expect { call_provider(service, system: "sys", prompt: "p") }
          .to raise_error(AiService::TimeoutError, "Network error calling #{name}: boom")
        expect(attempts.size).to eq(service_class::RETRY_OPTIONS[:max] + 1)
        expect(attempts.uniq).to eq([ { timeout: AiService::READ_TIMEOUT, long_running: false, single_attempt: false } ])
      end

      it "marks a read timeout above READ_TIMEOUT as long running and makes one attempt" do
        attempts = []
        service = failing_service(service_class, attempts)
        timeout = AiService::READ_TIMEOUT + 1

        expect { call_provider(service, system: "sys", prompt: "p", read_timeout: timeout) }
          .to raise_error(AiService::TimeoutError, "Network error calling #{name}: boom")
        expect(attempts).to eq([ { timeout: timeout, long_running: true, single_attempt: false } ])
      end

      it "marks a single-attempt request and makes one attempt at the default timeout" do
        attempts = []
        service = failing_service(service_class, attempts)

        expect { call_provider(service, system: "sys", prompt: "p", single_attempt: true) }
          .to raise_error(AiService::TimeoutError, "Network error calling #{name}: boom")
        expect(attempts).to eq([ { timeout: AiService::READ_TIMEOUT, long_running: false, single_attempt: true } ])
      end

      it "maps a Faraday error other than a timeout to NetworkError" do
        attempts = []
        service = failing_service(service_class, attempts, error: Faraday::ConnectionFailed)

        expect { call_provider(service, system: "sys", prompt: "p") }
          .to raise_error(AiService::NetworkError, "Network error calling #{name}: boom")
      end
    end
  end

  it "takes an OpenAI route reasoning within an allowance as long running at the default timeout" do
    attempts = []
    service = failing_service(OpenaiService, attempts)

    expect {
      call_provider(service, system: "sys", prompt: "p", purpose: "judge_section", max_tokens: AiService::JUDGE_MAX_TOKENS)
    }.to raise_error(AiService::TimeoutError)
    expect(attempts).to eq([ { timeout: AiService::READ_TIMEOUT, long_running: true, single_attempt: false } ])
  end
end
