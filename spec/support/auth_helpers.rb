module AuthHelpers
  # Returns the record and the raw code, as the minting script prints it.
  def mint_trial_code(seats: 1, days: 7, cap: 12, expires_at: 1.week.from_now)
    InviteCode.mint(seats: seats, expires_at: expires_at, trial_days: days, daily_request_cap: cap)
  end

  def create_trial_user(email: nil, name: "Trial User", time_zone: "UTC", provider: "fake", cap: 12, days: 7,
                        house_key: "fake-house-key")
    invite, _code = mint_trial_code(cap: cap, days: days)
    stub_env(HouseKeys.variable(provider, "API_KEY") => house_key)
    User.create!(email: email || "trial-#{SecureRandom.hex(4)}@example.com", name: name,
                 time_zone: time_zone, learning_track: LearningTrack::OFF).tap do |user|
      user.start_trial!(invite: invite, provider: provider, consented_at: Time.current)
    end
  end

  # The learning track backfill marked existing accounts "none"; a first-run spec passes learning_track: nil.
  def create_user_with_key(email: "dev@example.com", name: "Dev", time_zone: "UTC", learning_track: LearningTrack::OFF)
    user = User.create!(email: email, name: name, time_zone: time_zone, learning_track: learning_track)
    user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test-key" })
    user
  end

  # Every system spec logs in as this fake-provider user; a new account starts at the gate's two-section floor.
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

  # The code is minted after the POST because #authenticate_login_code reads the current digest.
  def login_as(user)
    post login_path, params: { email: user.email }
    post verify_login_code_path, params: { code: user.generate_login_code! }
  end

  def visit_as(user)
    visit login_path
    fill_in "Work email *", with: user.email
    click_button "Send code"

    fill_in "6-digit code from the email", with: user.generate_login_code!
    click_button "Verify code"
  end

  # A hardcoded wrong code could match the random real one, so derive one that never collides.
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
