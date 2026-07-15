class User < ApplicationRecord
  has_many :daily_exercises, dependent: :destroy
  has_many :daily_responses, dependent: :destroy
  has_many :api_usages,      dependent: :destroy

  # Encrypt the user's provider API key at rest. Requires RAILS_MASTER_KEY /
  # credentials to be set (standard Rails setup).
  encrypts :api_key

  LANGUAGES = %w[ruby_rails javascript mixed].freeze

  validates :email, presence: true, uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name,  presence: true
  validates :skill_level, inclusion: { in: %w[beginner developing solid strong] }
  validates :provider, inclusion: { in: %w[anthropic gemini] }, allow_nil: true
  validates :language, inclusion: { in: LANGUAGES }

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

  # ── API key ───────────────────────────────────────────────────────────────
  def api_key_present?
    api_key.present?
  end

  # ── Recent performance for prompt context ─────────────────────────────────
  # Last N sessions by count, not a calendar window — matches the "last 10
  # sessions" contract embedded verbatim in AiService's generation prompt.
  def recent_performance(limit: 10)
    daily_responses
      .includes(:daily_exercise)
      .order(date: :desc)
      .limit(limit)
      .map do |r|
        {
          date:          r.date.to_s,
          rating:        r.rating,
          feedback:      r.feedback_text,
          concepts:      r.concept_tags,
          sections_answered: r.answered_sections.size
        }
      end
  end

  # ── Language preference ────────────────────────────────────────────────────
  # Resolves the day's actual generation language. Pinned preferences return
  # themselves. "mixed" alternates by flipping the most recent PRIOR
  # exercise's language (excluding today's own row, so calling this multiple
  # times for the same day — e.g. on regenerate — stays consistent as long as
  # callers pass the result through rather than recomputing mid-day).
  def language_for_today
    return language unless language == "mixed"

    last = daily_exercises.where.not(date: Date.current).order(date: :desc).first
    return "ruby_rails" unless last

    last.language == "ruby_rails" ? "javascript" : "ruby_rails"
  end

  # ── Display ────────────────────────────────────────────────────────────────
  def provider_label
    I18n.t("providers.#{provider.presence || 'unknown'}")
  end
end
