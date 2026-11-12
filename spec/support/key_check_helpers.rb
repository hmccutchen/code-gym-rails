# No spec may reach a real provider, so every key check answers :accepted; `real_key_check: true` runs the real method.
module KeyCheckHelpers
  def key_check_fixture(name) = Rails.root.join("spec/fixtures/provider_errors", name).read

  # Swaps only the adapter, so the timeouts, headers and middleware under test are the provider's own.
  def stub_key_check(service_class, status: 200, body: "{}", error: nil)
    requests = []
    allow_any_instance_of(service_class).to receive(:key_check_connection).and_wrap_original do |original|
      original.call.tap do |connection|
        connection.builder.adapter(:test) do |stub|
          stub.get(service_class::MODELS_URL) do |env|
            requests << env
            raise error, "boom" if error

            [ status, {}, body ]
          end
        end
      end
    end
    requests
  end
end

RSpec.configure do |config|
  config.include KeyCheckHelpers

  config.before do |example|
    allow_any_instance_of(AiService).to receive(:check_key).and_return(:accepted) unless example.metadata[:real_key_check]
  end
end
