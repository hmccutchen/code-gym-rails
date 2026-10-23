# Design notes: docs/code-notes/app/models/concerns/second_factor.md
module SecondFactor
  extend ActiveSupport::Concern

  SECOND_FACTOR_DAILY_FAILURES = 20
  SECOND_FACTOR_FAILURE_WINDOW = 24.hours
  SECOND_FACTOR_CHALLENGE_FAILURES = 5
  SECOND_FACTOR_CHALLENGE_LIFETIME = 5.minutes
  RECENT_SIGN_IN = 15.minutes
  RECOVERY_CODE_COUNT = 10
  RECOVERY_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".freeze
  RECOVERY_CODE_SHAPE = /\A[#{RECOVERY_CODE_ALPHABET}]{10}\z/
  TOTP_ISSUER = "Coding Gym".freeze
  TOTP_INTERVAL = 30

  Outcome = Data.define(:status, :recovery_codes, :changed_at, :remaining, :retry_at) do
    def initialize(status:, recovery_codes: [], changed_at: nil, remaining: nil, retry_at: nil) = super

    def accepted? = status.in?(%i[totp recovery_code])
  end

  included do
    encrypts :otp_secret
  end

  def two_factor_enabled?
    two_factor_enabled_at.present?
  end

  def recovery_codes_remaining
    otp_backup_codes.to_a.size
  end

  def authenticator_uri
    totp_for(otp_secret).provisioning_uri(email)
  end

  def prepare_second_factor!
    with_lock do
      next if two_factor_enabled?
      update!(otp_secret: ROTP::Base32.random) if otp_secret.blank?
      otp_secret
    end
  end

  def enable_second_factor!(code)
    with_lock do
      next Outcome.new(status: :already_on) if two_factor_enabled?
      step = otp_secret.present? && matching_totp_step(normalize_code(code))
      next Outcome.new(status: :rejected) unless step

      now = Time.current.floor(6)
      codes = new_recovery_codes
      update!(consumed_timestep: step, two_factor_enabled_at: now, sessions_valid_after: now,
              otp_backup_codes: recovery_code_digests(codes))
      Outcome.new(status: :enabled, recovery_codes: codes, changed_at: now, remaining: codes.size)
    end
  end

  def verify_second_factor!(code)
    with_lock { verify_under_lock(code) }
  end

  def issue_second_factor_challenge!
    now = Time.current.floor(6)
    with_lock { update!(second_factor_challenge_at: now, second_factor_challenge_failures: 0) }
    now
  end

  def second_factor_challenge_open?(issued_at)
    issued = Time.iso8601(issued_at.to_s)
    second_factor_challenge_at.present? && issued == second_factor_challenge_at &&
      second_factor_challenge_at > SECOND_FACTOR_CHALLENGE_LIFETIME.ago
  rescue ArgumentError
    false
  end

  def answer_second_factor_challenge!(code, issued_at:)
    with_lock do
      next Outcome.new(status: :expired) unless second_factor_challenge_open?(issued_at)

      settle_second_factor_challenge(verify_under_lock(code))
    end
  end

  def regenerate_recovery_codes!(code)
    with_lock do
      verified = verify_under_lock(code)
      next verified unless verified.accepted?

      codes = new_recovery_codes
      update!(otp_backup_codes: recovery_code_digests(codes))
      Outcome.new(status: :regenerated, recovery_codes: codes, remaining: codes.size)
    end
  end

  def disable_second_factor!(code)
    with_lock do
      next Outcome.new(status: :already_off) unless two_factor_enabled?
      verified = verify_under_lock(code)
      next verified unless verified.accepted?

      now = Time.current.floor(6)
      update!(otp_secret: nil, consumed_timestep: nil, otp_backup_codes: nil,
              two_factor_enabled_at: nil, sessions_valid_after: now)
      Outcome.new(status: :disabled, changed_at: now)
    end
  end

  private

  def verify_under_lock(code)
    return Outcome.new(status: :locked, retry_at: second_factor_failures_since + SECOND_FACTOR_FAILURE_WINDOW) if second_factor_locked?

    outcome = check_second_factor(normalize_code(code))
    record_second_factor_failure unless outcome.accepted?
    outcome
  end

  def settle_second_factor_challenge(outcome)
    return end_second_factor_challenge(outcome) unless outcome.status == :rejected

    failures = second_factor_challenge_failures + 1
    return end_second_factor_challenge(Outcome.new(status: :challenge_ended)) if failures >= SECOND_FACTOR_CHALLENGE_FAILURES

    update!(second_factor_challenge_failures: failures)
    outcome
  end

  def end_second_factor_challenge(outcome)
    update!(second_factor_challenge_at: nil, second_factor_challenge_failures: 0)
    outcome
  end

  def check_second_factor(code)
    return Outcome.new(status: :rejected) unless two_factor_enabled?

    code.match?(RECOVERY_CODE_SHAPE) ? use_recovery_code(code) : use_totp(code)
  end

  def use_totp(code)
    step = matching_totp_step(code)
    return Outcome.new(status: :rejected) unless step

    update!(consumed_timestep: step)
    Outcome.new(status: :totp)
  end

  def use_recovery_code(code)
    digest = otp_backup_codes.to_a.find { |stored| BCrypt::Password.new(stored) == code }
    return Outcome.new(status: :rejected) unless digest

    update!(otp_backup_codes: otp_backup_codes - [ digest ])
    Outcome.new(status: :recovery_code, remaining: otp_backup_codes.size)
  end

  def matching_totp_step(code)
    after = consumed_timestep && consumed_timestep * TOTP_INTERVAL
    timestamp = totp_for(otp_secret).verify(code, drift_behind: TOTP_INTERVAL, drift_ahead: TOTP_INTERVAL, after: after)
    timestamp && timestamp / TOTP_INTERVAL
  end

  def second_factor_locked?
    second_factor_failures >= SECOND_FACTOR_DAILY_FAILURES && second_factor_window_open?
  end

  def second_factor_window_open?
    second_factor_failures_since.present? && second_factor_failures_since > SECOND_FACTOR_FAILURE_WINDOW.ago
  end

  def record_second_factor_failure
    if second_factor_window_open?
      update!(second_factor_failures: second_factor_failures + 1)
    else
      update!(second_factor_failures: 1, second_factor_failures_since: Time.current)
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
      letters = Array.new(10) { RECOVERY_CODE_ALPHABET[SecureRandom.random_number(RECOVERY_CODE_ALPHABET.size)] }
      "#{letters.first(5).join}-#{letters.last(5).join}"
    end
  end

  def recovery_code_digests(codes)
    codes.map { |code| BCrypt::Password.create(normalize_code(code)) }
  end
end
