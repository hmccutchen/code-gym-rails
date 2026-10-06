module AuthHelpers
  # Both builders stand for accounts that already exist, which the learning
  # track backfill marked "none". A first-run spec passes learning_track: nil.
  # A new account needs a seat on an invite code; a join code admits one
  # without a trial. Returns the raw code, as the minting script prints it.
  def mint_join_code(seats: 1, expires_at: 1.week.from_now)
    InviteCode.mint(seats: seats, expires_at: expires_at).last
  end

  def mint_trial_code(provider: "fake", seats: 1, days: 7, cap: 12, expires_at: 1.week.from_now)
    InviteCode.mint(seats: seats, expires_at: expires_at, provider: provider, trial_days: days, daily_request_cap: cap)
  end

  # A trial account: no key of its own, a redeemed trial code, and the house
  # key for its provider stubbed into ENV.
  def create_trial_user(email: nil, name: "Trial User", time_zone: "UTC", provider: "fake", cap: 12, days: 7,
                        house_key: "fake-house-key")
    _invite, code = mint_trial_code(provider: provider, cap: cap, days: days)
    stub_env(HouseKeys.variable(provider, "API_KEY") => house_key)
    User.create!(email: email || "trial-#{SecureRandom.hex(4)}@example.com", name: name,
                 time_zone: time_zone, learning_track: LearningTrack::OFF).tap do |user|
      user.start_trial!(code: code, consented_at: Time.current)
    end
  end

  def create_user_with_key(email: "dev@example.com", name: "Dev", time_zone: "UTC", learning_track: LearningTrack::OFF)
    user = User.create!(email: email, name: name, time_zone: time_zone, learning_track: learning_track)
    user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test-key" })
    user
  end

  # Test-only infrastructure, not demo content — deliberately not seeded via
  # PreviewSeed/db/seeds.rb. Every system spec logs in as one of these, never
  # a real-key user, so no system spec ever needs (or can reach) a real API key.
  # A new account starts at the competency gate's floor, which holds only the
  # fixed kinds; a spec that answers an optional section asks for a full day.
  def create_fake_provider_user(email: nil, name: "Fake User", time_zone: "UTC", learning_track: LearningTrack::OFF,
                                daily_section_count: nil)
    User.create!(
      email: email || "fake-user-#{SecureRandom.hex(4)}@example.com",
      name: name,
      time_zone: time_zone,
      learning_track: learning_track,
      daily_section_count: daily_section_count,
      provider: "fake", api_keys: { "fake" => "fake-test-key" }
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
    post verify_login_code_path, params: { code: user.generate_login_code! }
  end

  # System specs drive a real browser via Capybara, so login must be real page
  # loads rather than bare requests.
  def visit_as(user)
    visit login_path
    fill_in "Work email *", with: user.email
    click_button "Send code"

    fill_in "6-digit code from the email", with: user.generate_login_code!
    click_button "Verify code"
  end

  # The generated code is random, so a hardcoded "wrong" code can occasionally
  # be the real one. Derive one that never collides.
  def wrong_code_for(raw_code)
    format("%06d", (raw_code.to_i + 1) % 1_000_000)
  end
end

RSpec.configure do |config|
  config.include AuthHelpers, type: :request
  config.include AuthHelpers, type: :channel
  config.include AuthHelpers, type: :helper
  config.include AuthHelpers, type: :system
  config.include AuthHelpers, type: :job
  config.include AuthHelpers, type: :model
end
