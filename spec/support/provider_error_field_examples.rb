RSpec.shared_examples "a provider reading an error field that is not an object" do
  include AuthHelpers

  let(:user) { create_user_with_key }

  def failed_logged_call(status, body, error_class: ProviderError, message: nil)
    service.instance_variable_set(:@conn, stubbed_connection([ [ status, body.to_json ] ]))
    request = AiService::Request.build(purpose: "duck_thread", system: "sys", prompt: "p", single_attempt: true)
    expect { service.send(:call_and_log, user, request) }.to raise_error(*[ error_class, message ].compact)
  end

  before { allow(Rails.logger).to receive(:error) }

  [ "upstream down", [ "upstream down" ] ].each do |error|
    it "raises ProviderError and records one usage row when error is #{error.inspect}" do
      expect { failed_logged_call(500, { "error" => error }) }.to change(ApiUsage, :count).by(1)
    end
  end

  [ { "text" => "upstream down" }, [ "upstream down" ], 500 ].each do |message|
    it "raises ProviderError with the fallback wording and records one usage row when message is #{message.inspect}" do
      fallback = "#{service.send(:provider_name)} API error 500"
      body = { "error" => { "type" => "api_error", "message" => message } }

      expect { failed_logged_call(500, body, message: fallback) }.to change(ApiUsage, :count).by(1)
    end
  end
end
