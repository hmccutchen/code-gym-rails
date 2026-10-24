module PushCredentials
  PUBLIC_KEY = "BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U".freeze
  PRIVATE_KEY = "private".freeze

  def with_push_credentials(&block)
    with_push_env({ WebPushCredentials::PUBLIC_KEY_VAR => PUBLIC_KEY, WebPushCredentials::PRIVATE_KEY_VAR => PRIVATE_KEY }, &block)
  end

  def without_push_credentials(&block)
    with_push_env({ WebPushCredentials::PUBLIC_KEY_VAR => nil, WebPushCredentials::PRIVATE_KEY_VAR => nil }, &block)
  end

  private

  def with_push_env(values)
    original = ENV.slice(*values.keys)
    values.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    yield
  ensure
    values.each_key { |name| original.key?(name) ? ENV[name] = original[name] : ENV.delete(name) }
  end
end

RSpec.configure do |config|
  %i[system request job].each { |type| config.include PushCredentials, type: type }
end
