class ApiUsage < ApplicationRecord
  belongs_to :user

  PURPOSES = %w[generate_exercise retry_section review_response assess_difficulty generate_concept_reference generate_recognition_guide explain_concept_differently explain_differently review_follow_up duck_thread pseudocode_critique pseudocode_translate judge_section judge_review].freeze

  # Why a call's reply was not used, or nil when it was. AiService.failure_code_for
  # maps its errors onto this list; a row with a failure and tokens was billed
  # for a reply the app refused (a refusal, a truncation), one with zero tokens
  # never got a reply.
  FAILURES = %w[rate_limit authentication out_of_credit timeout network refusal truncated invalid_response provider_error].freeze

  validates :purpose, inclusion: { in: PURPOSES }
  validates :failure, inclusion: { in: FAILURES }, allow_nil: true
  validates :date, :tokens_in, :tokens_out, presence: true

  scope :failed, -> { where.not(failure: nil) }

  # Calls one account made on one of its own local days, attempts included: a
  # refused call still counted against the provider.
  def self.requests_on(user, day, provider:)
    where(user: user, date: day, provider: provider).count
  end

  # Calls billed to a house key inside one of the provider's own quota days,
  # by created_at in the zone the provider resets in rather than any user's
  # date. The guard that reads it arrives with trial mode.
  def self.house_requests_between(provider:, from:, to:)
    where(provider: provider, house_key: true, created_at: from...to).count
  end
end
