module AuthHelpers
  def create_user_with_key(email: "dev@example.com", name: "Dev", time_zone: "UTC")
    user = User.create!(email: email, name: name, time_zone: time_zone)
    user.update!(api_key: "sk-ant-test-key", provider: "anthropic")
    user
  end

  # Test-only infrastructure, not demo content — deliberately not seeded via
  # PreviewSeed/db/seeds.rb. Every system spec logs in as one of these, never
  # a real-key user, so no system spec ever needs (or can reach) a real API key.
  def create_fake_provider_user(email: "fake-user@example.com", name: "Fake User", time_zone: "UTC")
    user = User.create!(email: email, name: name, time_zone: time_zone)
    user.update!(api_key: "fake-test-key", provider: "fake")
    user
  end

  def login_as(user)
    get verify_auth_path(token: user.generate_login_token!)
  end
end

RSpec.configure do |config|
  config.include AuthHelpers, type: :request
  config.include AuthHelpers, type: :channel
  config.include AuthHelpers, type: :helper
end
