module ProviderCallHelpers
  def call_provider(service, system:, prompt:, **settings)
    service.send(:call, AiService::Request.build(system: system, prompt: prompt, **settings))
  end
end

RSpec.configure { |config| config.include ProviderCallHelpers }
