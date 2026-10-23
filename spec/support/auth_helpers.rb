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
                 time_zone: time_zone, **chosen_track(true)).tap do |user|
      user.start_trial!(invite: invite, provider: provider, consented_at: Time.current)
    end
  end

  # Accounts have chosen a track, as the dual-write release writes it, unless a first-run spec passes track_chosen: false.
  def create_user_with_key(email: "dev@example.com", name: "Dev", time_zone: "UTC", track_chosen: true)
    user = User.create!(email: email, name: name, time_zone: time_zone, **chosen_track(track_chosen))
    user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test-key" })
    user
  end

  # Every system spec logs in as this fake-provider user; a new account starts at the gate's two-section floor.
  def create_fake_provider_user(email: nil, name: "Fake User", time_zone: "UTC", track_chosen: true,
                                daily_section_count: nil)
    User.create!(
      email: email || "fake-user-#{SecureRandom.hex(4)}@example.com",
      name: name,
      time_zone: time_zone,
      **chosen_track(track_chosen),
      daily_section_count: daily_section_count,
      provider: "fake", api_keys: { "fake" => "fake-test-key" }
    )
  end

  def chosen_track(chosen)
    { track_chosen_at: chosen ? Time.current : nil }
  end

  SPEC_PASSWORD = "correct horse battery staple".freeze

  # Warden directly, as Devise's own helper does, since its sign_in calls a login_as this one shadows.
  def login_as(user)
    finish_account_setup(user)
    Warden.on_next_request { |proxy| proxy.set_user(User.find(user.id), scope: :user, event: :authentication) }
  end

  def visit_as(user)
    login_as(user)
    visit root_path
  end

  def finish_account_setup(user)
    return if user.password_set? && user.two_factor_enrolled?

    user.update_columns(encrypted_password: Devise::Encryptor.digest(User, SPEC_PASSWORD), otp_required_for_login: true)
  end

  def enroll_two_factor(user, password: SPEC_PASSWORD)
    user.update!(password: password, otp_secret: User.generate_otp_secret, otp_required_for_login: true)
    user
  end

  # A hardcoded wrong code could match the random real one, so derive one that never collides.
  def wrong_code_for(raw_code)
    format("%06d", (raw_code.to_i + 1) % 1_000_000)
  end
end

RSpec.configure do |config|
  config.before { Warden.test_mode! }
  config.after  { Warden.test_reset! }
  config.include AuthHelpers, type: :request
  config.include AuthHelpers, type: :channel
  config.include AuthHelpers, type: :helper
  config.include AuthHelpers, type: :system
  config.include AuthHelpers, type: :job
  config.include AuthHelpers, type: :model
end
