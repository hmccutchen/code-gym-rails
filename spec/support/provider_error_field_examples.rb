RSpec.shared_examples "a provider reading an error field that is not an object" do
  include AuthHelpers

  let(:user) { create_user_with_key }

  def failed_logged_call(status, body, error_class: ProviderError)
    service.instance_variable_set(:@conn, stubbed_connection([ [ status, body.to_json ] ]))
    request = AiService::Request.build(purpose: "duck_thread", system: "sys", prompt: "p", single_attempt: true)
    expect { service.send(:call_and_log, user, request) }.to raise_error(error_class)
  end

  before { allow(Rails.logger).to receive(:error) }

  [ "upstream down", [ "upstream down" ] ].each do |error|
    it "raises ProviderError and records one usage row when error is #{error.inspect}" do
      expect { failed_logged_call(500, { "error" => error }) }.to change(ApiUsage, :count).by(1)
    end
  end
end
