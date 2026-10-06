# When a failed call's limit lifts, so a sentence can name the time in the
# user's zone and say when it has already passed. Pure over the values it is
# given; nothing here reads the clock.
#
# A daily limit's boundary is the provider's own fact (Gemini's quota day ends
# at midnight Pacific), so each provider class answers `daily_quota_reset_at`
# and an unknown provider gets the base class's day from the failure. A short
# limit lifts after the wait the provider asked for, or a minute. A trial
# allowance resets when the gate that refused the call said it would.
class ResetClock
  SHORT_WAIT = 1.minute

  def self.reset_at(kind, provider:, failed_at:, retry_after: nil)
    case kind.to_s
    when "daily_limit"          then (AiProvider.find(provider.to_s) || AiService).daily_quota_reset_at(failed_at)
    when "short_rate_limit"     then failed_at + [ retry_after.to_i, SHORT_WAIT ].max
    when "trial_allowance_used" then failed_at + retry_after.to_i
    end
  end
end
