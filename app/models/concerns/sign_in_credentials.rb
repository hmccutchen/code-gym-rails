# Design notes: docs/code-notes/app/models/concerns/sign_in_credentials.md
module SignInCredentials
  extend ActiveSupport::Concern

  BACKUP_CODE_COUNT = 10

  # Prepended because `devise` includes its modules after this one, so they would win otherwise.
  module DeviseOverrides
    def active_for_authentication?
      super && !anonymized?
    end

    def confirmation_required?
      !confirmed? && (@signing_up || confirmation_token.present?)
    end

    def otp_required_for_login = true
  end

  included do
    devise :two_factor_authenticatable, :two_factor_backupable, :registerable, :recoverable, :confirmable,
           otp_backup_code_length: 5, otp_number_of_backup_codes: BACKUP_CODE_COUNT
    prepend DeviseOverrides

    attr_accessor :password_required
    attr_writer :signing_up

    validates :password, presence: true, if: :password_required
    validates :password, length: { in: Devise.password_length }, confirmation: true, allow_nil: true
  end

  class_methods do
    def awaiting_password
      active.where(encrypted_password: "")
    end
  end

  def password_set? = encrypted_password.present?

  def two_factor_enrolled? = self[:otp_required_for_login]

  # Under the row lock, so a double-submitted form cannot write two sets and show the person the losing one.
  def enroll_two_factor!(code)
    with_lock do
      return nil if two_factor_enrolled? || otp_secret.blank? || !validate_and_consume_otp!(code)

      backup_codes = generate_otp_backup_codes!
      update!(otp_required_for_login: true)
      backup_codes
    end
  end

  def regenerate_backup_codes!(code)
    with_lock do
      return nil unless two_factor_enrolled? && validate_and_consume_otp!(code)

      generate_otp_backup_codes!.tap { save!(validate: false) }
    end
  end

  def prepare_two_factor_secret!
    update!(otp_secret: self.class.generate_otp_secret) if otp_secret.blank?
    otp_secret
  end

  def sign_in_credentials_cleared
    { encrypted_password: "", otp_secret: nil, otp_required_for_login: false, otp_backup_codes: nil,
      consumed_timestep: nil, reset_password_token: nil, confirmation_token: nil,
      login_code_sent_at: nil, login_code_digest: nil, login_code_attempts: 0 }
  end
end
