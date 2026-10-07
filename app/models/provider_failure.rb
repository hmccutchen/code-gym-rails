# The kind of provider failure a page can explain, read from the error at the
# boundary that rescues it. Pure: an error in, one of KINDS out. The text for
# each kind is ProviderFailureText's; the reset time ResetClock's.
#
# A 429 is a daily limit when the provider named a per-day quota or asked for
# a wait of an hour or more, and a short limit otherwise. A spend limit or an
# empty balance is never a limit of either kind, whatever status carried it:
# the providers raise BillingError for those before this is asked.
class ProviderFailure
  KINDS = %w[daily_limit short_rate_limit bad_key out_of_credit outage timeout other].freeze
  DAILY_WAIT = 1.hour
  DAILY_QUOTA_PATTERN = /PerDay/i

  def self.classify(error)
    case error
    when AiService::BillingError        then "out_of_credit"
    when AiService::AuthenticationError then "bad_key"
    when AiService::RateLimitError      then rate_limit_kind(error)
    when AiService::TimeoutError, Timeout::Error then "timeout"
    when AiService::NetworkError        then "outage"
    when AiService::Error               then error.http_status.to_i >= 500 ? "outage" : "other"
    else                                     "other"
    end
  end

  # A 5xx raised as a rate limit (Claude's 529, "overloaded") is the provider
  # being down for everyone, not this key's limit.
  def self.rate_limit_kind(error)
    return "outage" if error.http_status.to_i >= 500
    daily?(error) ? "daily_limit" : "short_rate_limit"
  end

  def self.daily?(error)
    error.quota_id.to_s.match?(DAILY_QUOTA_PATTERN) || error.retry_after.to_i >= DAILY_WAIT
  end

  def self.kind?(value) = KINDS.include?(value.to_s)
end
