# The kind of provider failure a page can explain, read from the error at the
# boundary that rescues it. Pure: an error in, one of KINDS out. The text for
# each kind is ProviderFailureText's; the reset time ResetClock's.
#
# A 429 is a daily limit when the provider named a per-day quota or asked for
# a wait of an hour or more, and a short limit otherwise. A spend limit or an
# empty balance is never a limit of either kind, whatever status carried it:
# the providers raise BillingError for those before this is asked.
class ProviderFailure
  TRIAL_KINDS = %w[trial_allowance_used trial_ended].freeze
  KINDS = (%w[daily_limit short_rate_limit bad_key out_of_credit outage timeout other] + TRIAL_KINDS).freeze
  DAILY_WAIT = 1.hour
  DAILY_QUOTA_PATTERN = /PerDay/i

  def self.classify(error)
    case error
    when AiService::TrialAllowanceError then "trial_allowance_used"
    when AiService::TrialEndedError     then "trial_ended"
    when AiService::BillingError        then "out_of_credit"
    when AiService::AuthenticationError then "bad_key"
    when AiService::RateLimitError      then daily?(error) ? "daily_limit" : "short_rate_limit"
    when AiService::TimeoutError, Timeout::Error then "timeout"
    when AiService::NetworkError        then "outage"
    when AiService::Error               then error.http_status.to_i >= 500 ? "outage" : "other"
    else                                     "other"
    end
  end

  def self.daily?(error)
    error.quota_id.to_s.match?(DAILY_QUOTA_PATTERN) || error.retry_after.to_i >= DAILY_WAIT
  end

  def self.kind?(value) = KINDS.include?(value.to_s)

  def self.trial_kind?(value) = TRIAL_KINDS.include?(value.to_s)
end
