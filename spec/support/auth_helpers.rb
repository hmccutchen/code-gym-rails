module AuthHelpers
  def create_user_with_key(email: "dev@example.com", name: "Dev", time_zone: "UTC")
    user = User.create!(email: email, name: name, time_zone: time_zone)
    user.update!(api_key: "sk-ant-test-key", provider: "anthropic")
    user
  end

  # Test-only infrastructure, not demo content — deliberately not seeded via
  # PreviewSeed/db/seeds.rb. Every system spec logs in as one of these, never
  # a real-key user, so no system spec ever needs (or can reach) a real API key.
  def create_fake_provider_user(email: nil, name: "Fake User", time_zone: "UTC")
    User.create!(
      email: email || "fake-user-#{SecureRandom.hex(4)}@example.com",
      name: name,
      time_zone: time_zone,
      api_key: "fake-test-key",
      provider: "fake"
    )
  end

  # `get`/request-spec style — used by request/channel/helper specs, which
  # don't drive a real browser.
  #
  # The POST establishes this session's pending-login state; the code is
  # minted afterwards because #authenticate_login_code reads whatever digest
  # is current, which keeps the helper off the mail queue entirely.
  def login_as(user)
    post login_path, params: { email: user.email }
    user.generate_login_token!
    post verify_login_code_path, params: { code: user.raw_login_code }
  end

  # System specs drive a real browser via Capybara, so login must be real page
  # loads rather than bare requests.
  def visit_as(user)
    visit login_path
    fill_in "Work email *", with: user.email
    click_button "Send code →"

    user.generate_login_token!
    fill_in "6-digit code from the email", with: user.raw_login_code
    click_button "Verify code →"
  end
end

RSpec.configure do |config|
  config.include AuthHelpers, type: :request
  config.include AuthHelpers, type: :channel
  config.include AuthHelpers, type: :helper
  config.include AuthHelpers, type: :system
  config.include AuthHelpers, type: :job
end
