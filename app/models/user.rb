class User < ApplicationRecord
  has_many :daily_exercises, dependent: :destroy
  has_many :daily_responses, dependent: :destroy
  has_many :api_usages,      dependent: :destroy

  # Encrypt Anthropic API key at rest using Rails 7+ ActiveRecord Encryption.
  # Requires RAILS_MASTER_KEY / credentials to be set (standard Rails setup).
  encrypts :api_key

  validates :email, presence: true, uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name,  presence: true
  validates :skill_level, inclusion: { in: %w[beginner developing solid strong] }

  before_save { email.downcase! }

  TOKEN_EXPIRY = 15.minutes

  # ── Magic link ────────────────────────────────────────────────────────────
  def generate_login_token!
    raw_token = SecureRandom.urlsafe_base64(32)
    update!(
      login_token_digest:   BCrypt::Password.create(raw_token),
      login_token_sent_at:  Time.current
    )
    raw_token
  end

  def self.find_by_login_token(raw_token)
    # We can't query by the digest directly since each BCrypt hash is salted,
    # so we do a two-step lookup: find candidates sent within the expiry window,
    # then verify the digest in Ruby.
    candidates = where("login_token_sent_at > ?", TOKEN_EXPIRY.ago)
                   .where.not(login_token_digest: nil)
    candidates.find { |u| BCrypt::Password.new(u.login_token_digest) == raw_token }
  end

  def clear_login_token!
    update!(login_token_digest: nil, login_token_sent_at: nil)
  end

  def login_token_expired?
    login_token_sent_at.nil? || login_token_sent_at < TOKEN_EXPIRY.ago
  end

  # ── API key ───────────────────────────────────────────────────────────────
  def api_key_present?
    api_key.present?
  end

  # ── Usage helpers ─────────────────────────────────────────────────────────
  def monthly_token_usage(month = Date.current.beginning_of_month)
    api_usages
      .where(date: month..month.end_of_month)
      .sum(:tokens_in) + api_usages.where(date: month..month.end_of_month).sum(:tokens_out)
  end

  # ── Recent performance for prompt context ─────────────────────────────────
  def recent_performance(days: 7)
    daily_responses
      .includes(:daily_exercise)
      .where("date >= ?", days.days.ago.to_date)
      .order(date: :desc)
      .map do |r|
        {
          date:          r.date.to_s,
          rating:        r.rating,
          feedback:      r.feedback_text,
          concepts:      r.concept_tags,
          sections_answered: r.answers.count { |_, v| v.to_s.length > 10 }
        }
      end
  end
end
