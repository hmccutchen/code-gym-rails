# Billing failures never reach here as limits: providers raise BillingError before a 429 is classified.
class ProviderFailure
  TRIAL_KINDS = %w[trial_allowance_used trial_ended].freeze
  KINDS = (%w[daily_limit short_rate_limit bad_key out_of_credit outage timeout setup other] + TRIAL_KINDS).freeze
  DAILY_WAIT = 1.hour
  DAILY_QUOTA_PATTERN = /PerDay/i

  def self.classify(error)
    case error
    when ProviderError::RateLimitError then rate_limit_kind(error)
    when ProviderError                 then error.class.failure_kind || status_kind(error)
    when Timeout::Error                then ProviderError::TimeoutError.failure_kind
    when SetupError                    then "setup"
    else                                    "other"
    end
  end

  def self.status_kind(error) = error.http_status.to_i >= 500 ? "outage" : "other"

  # A 5xx rate limit (Claude's 529, "overloaded") is a provider outage, not this key's limit.
  def self.rate_limit_kind(error)
    return "outage" if error.http_status.to_i >= 500
    daily?(error) ? "daily_limit" : "short_rate_limit"
  end

  def self.daily?(error)
    error.quota_id.to_s.match?(DAILY_QUOTA_PATTERN) || error.retry_after.to_i >= DAILY_WAIT
  end

  def self.kind?(value) = KINDS.include?(value.to_s)

  def self.trial_kind?(value) = TRIAL_KINDS.include?(value.to_s)
end
