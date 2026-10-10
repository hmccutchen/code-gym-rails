# Pure: never reads the clock; each provider class owns its daily_quota_reset_at.
class ResetClock
  SHORT_WAIT = 1.minute

  def self.reset_at(kind, provider:, failed_at:, retry_after: nil)
    case kind.to_s
    when "daily_limit"          then [ daily_boundary(provider, failed_at), failed_at + retry_after.to_i ].max
    when "short_rate_limit"     then failed_at + [ retry_after.to_i, SHORT_WAIT ].max
    when "trial_allowance_used" then failed_at + retry_after.to_i
    end
  end

  def self.daily_boundary(provider, failed_at)
    (AiProvider.find(provider.to_s) || AiService).daily_quota_reset_at(failed_at)
  end
end
