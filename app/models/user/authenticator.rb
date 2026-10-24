# Design notes: docs/code-notes/app/models/user/authenticator.md
class User::Authenticator
  DAILY_FAILURES = 20
  FAILURE_WINDOW = 24.hours
  CHALLENGE_FAILURES = 5
  CHALLENGE_LIFETIME = 5.minutes
  DOUBLE_TAP_WINDOW = 30.seconds
  RECOVERY_CODE_COUNT = 10
  RECOVERY_CODE_LENGTH = 10
  RECOVERY_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".freeze
  RECOVERY_CODE_SHAPE = /\A[#{RECOVERY_CODE_ALPHABET}]{#{RECOVERY_CODE_LENGTH}}\z/
  TOTP_ISSUER = "Coding Gym".freeze
  TOTP_INTERVAL = 30

  Outcome = Data.define(:status, :recovery_codes, :changed_at, :remaining, :retry_at) do
    def initialize(status:, recovery_codes: [], changed_at: nil, remaining: nil, retry_at: nil) = super

    def accepted? = status.in?(%i[totp recovery_code])
  end

  def self.new_secret = ROTP::Base32.random

  def initialize(user)
    @user = user
  end

  def enabled?
    user.two_factor_enabled_at.present?
  end

  def sign_in_factor = enabled? ? :authenticator : :emailed_code

  def emailed_code_signs_in? = sign_in_factor == :emailed_code

  def recovery_codes_remaining
    user.otp_backup_codes.to_a.size
  end

  def provisioning_uri(secret)
    totp_for(secret).provisioning_uri(user.email)
  end

  # The secret is the setup page's own, from its session; it reaches the row only here, once a code for it verifies.
  def enable!(code, secret:)
    step = secret.present? && matching_totp_step(normalize_code(code), secret)
    codes = step ? new_recovery_codes : []
    digests = recovery_code_digests(codes)
    user.with_lock do
      next Outcome.new(status: :already_on) if enabled?
      next Outcome.new(status: :rejected) unless step

      now = Time.current.floor(6)
      user.update!(otp_secret: secret, consumed_timestep: step, two_factor_enabled_at: now, sessions_valid_after: now,
                   otp_backup_codes: digests)
      Outcome.new(status: :enabled, recovery_codes: codes, changed_at: now, remaining: codes.size)
    end
  end

  def verify!(code)
    user.with_lock { verify_under_lock(code) }
  end

  # A double tap's two posts both carry the cookie from before either, so both must name the same open challenge.
  def issue_challenge!
    now = Time.current.floor(6)
    user.with_lock do
      next user.second_factor_challenge_at if user.second_factor_challenge_at&.>(now - DOUBLE_TAP_WINDOW)

      user.update!(second_factor_challenge_at: now, second_factor_challenge_failures: 0)
      now
    end
  end

  def challenge_open?(issued_at)
    issued = User.session_time(issued_at)
    open_at = user.second_factor_challenge_at
    issued.present? && open_at.present? && issued == open_at && open_at > CHALLENGE_LIFETIME.ago
  end

  def answer_challenge!(code, issued_at:)
    user.with_lock do
      next Outcome.new(status: :expired) unless challenge_open?(issued_at)

      settle_challenge(verify_under_lock(code)).tap { |outcome| yield outcome if block_given? && outcome.accepted? }
    end
  end

  def regenerate_recovery_codes!(code)
    codes = new_recovery_codes
    digests = recovery_code_digests(codes)
    user.with_lock do
      verified = verify_under_lock(code)
      next verified unless verified.accepted?

      user.update!(otp_backup_codes: digests)
      Outcome.new(status: :regenerated, recovery_codes: codes, remaining: codes.size)
    end
  end

  def disable!(code)
    user.with_lock do
      next Outcome.new(status: :already_off) unless enabled?
      verified = verify_under_lock(code)
      next verified unless verified.accepted?

      now = Time.current.floor(6)
      user.update!(otp_secret: nil, consumed_timestep: nil, otp_backup_codes: nil,
                   two_factor_enabled_at: nil, sessions_valid_after: now)
      Outcome.new(status: :disabled, changed_at: now)
    end
  end

  private

  attr_reader :user

  def verify_under_lock(code)
    return Outcome.new(status: :locked, retry_at: user.second_factor_failures_since + FAILURE_WINDOW) if locked?

    outcome = check(normalize_code(code))
    record_failure unless outcome.accepted?
    outcome
  end

  def settle_challenge(outcome)
    return end_challenge(outcome) unless outcome.status == :rejected

    failures = user.second_factor_challenge_failures + 1
    return end_challenge(Outcome.new(status: :challenge_ended)) if failures >= CHALLENGE_FAILURES

    user.update!(second_factor_challenge_failures: failures)
    outcome
  end

  def end_challenge(outcome)
    user.update!(second_factor_challenge_at: nil, second_factor_challenge_failures: 0)
    outcome
  end

  def check(code)
    return Outcome.new(status: :rejected) unless enabled?

    code.match?(RECOVERY_CODE_SHAPE) ? use_recovery_code(code) : use_totp(code)
  end

  def use_totp(code)
    step = matching_totp_step(code)
    return Outcome.new(status: :rejected) unless step

    user.update!(consumed_timestep: step)
    Outcome.new(status: :totp)
  end

  def use_recovery_code(code)
    digest = user.otp_backup_codes.to_a.find { |stored| BCrypt::Password.new(stored) == code }
    return Outcome.new(status: :rejected) unless digest

    user.update!(otp_backup_codes: user.otp_backup_codes - [ digest ])
    Outcome.new(status: :recovery_code, remaining: user.otp_backup_codes.size)
  end

  def matching_totp_step(code, secret = user.otp_secret)
    after = user.consumed_timestep && user.consumed_timestep * TOTP_INTERVAL
    timestamp = totp_for(secret).verify(code, drift_behind: TOTP_INTERVAL, drift_ahead: TOTP_INTERVAL, after: after)
    timestamp && timestamp / TOTP_INTERVAL
  end

  def locked?
    user.second_factor_failures >= DAILY_FAILURES && failure_window_open?
  end

  def failure_window_open?
    user.second_factor_failures_since.present? && user.second_factor_failures_since > FAILURE_WINDOW.ago
  end

  def record_failure
    if failure_window_open?
      user.update!(second_factor_failures: user.second_factor_failures + 1)
    else
      user.update!(second_factor_failures: 1, second_factor_failures_since: Time.current)
    end
  end

  def totp_for(secret)
    ROTP::TOTP.new(secret, issuer: TOTP_ISSUER, interval: TOTP_INTERVAL)
  end

  def normalize_code(code)
    code.to_s.gsub(/[\s-]/, "").upcase
  end

  def new_recovery_codes
    Array.new(RECOVERY_CODE_COUNT) do
      letters = Array.new(RECOVERY_CODE_LENGTH) { RECOVERY_CODE_ALPHABET[SecureRandom.random_number(RECOVERY_CODE_ALPHABET.size)] }
      letters.each_slice(RECOVERY_CODE_LENGTH / 2).map(&:join).join("-")
    end
  end

  def recovery_code_digests(codes)
    codes.map { |code| BCrypt::Password.create(normalize_code(code)) }
  end
end
