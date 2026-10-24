module PushCredentials
  PUBLIC_KEY = "BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U".freeze
  PRIVATE_KEY = "private".freeze

  def with_push_credentials
    names = [ WebPushCredentials::PUBLIC_KEY_VAR, WebPushCredentials::PRIVATE_KEY_VAR ]
    original = ENV.slice(*names)
    ENV.update(WebPushCredentials::PUBLIC_KEY_VAR => PUBLIC_KEY, WebPushCredentials::PRIVATE_KEY_VAR => PRIVATE_KEY)
    yield
  ensure
    names.each { |name| original.key?(name) ? ENV[name] = original[name] : ENV.delete(name) }
  end
end

RSpec.configure do |config|
  %i[system request job].each { |type| config.include PushCredentials, type: type }
end
