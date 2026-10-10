class ApiUsage < ApplicationRecord
  belongs_to :user

  PURPOSES = %w[generate_exercise retry_section review_response assess_difficulty generate_concept_reference generate_recognition_guide explain_concept_differently explain_differently review_follow_up duck_thread pseudocode_critique pseudocode_translate judge_section judge_review].freeze

  # A failure with tokens was billed for a reply the app refused; one with zero tokens never got a reply.
  FAILURES = %w[rate_limit authentication out_of_credit timeout network refusal truncated invalid_response provider_error].freeze

  validates :purpose, inclusion: { in: PURPOSES }
  validates :failure, inclusion: { in: FAILURES }, allow_nil: true
  validates :date, :tokens_in, :tokens_out, presence: true

  scope :failed, -> { where.not(failure: nil) }

  # Counted by created_at, not `date`: a job outside the user's zone stamps `date` with the server's day.
  def self.requests_on(user, day, provider:)
    start = day.in_time_zone(user.effective_time_zone)
    where(user: user, provider: provider, created_at: start...start.tomorrow.beginning_of_day).count
  end

  # Counted by created_at in the zone the provider's quota resets in, not any user's date.
  def self.house_requests_between(provider:, from:, to:)
    where(provider: provider, house_key: true, created_at: from...to).count
  end
end
