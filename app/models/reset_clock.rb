# When a failed call's limit lifts, so a sentence can name the time in the
# user's zone and say when it has already passed. Pure over the values it is
# given; nothing here reads the clock.
#
# Gemini's daily quota resets at midnight Pacific, whatever the user's zone.
# No other provider has a daily request limit on the routes this app uses, so
# another provider's daily limit is given a day from the failure. A short
# limit lifts after the wait the provider asked for, or a minute.
class ResetClock
  GEMINI_RESET_ZONE = "America/Los_Angeles".freeze
  SHORT_WAIT = 1.minute

  def self.reset_at(kind, provider:, failed_at:, retry_after: nil)
    case kind.to_s
    when "daily_limit"      then daily_reset(provider, failed_at)
    when "short_rate_limit" then failed_at + [ retry_after.to_i, SHORT_WAIT ].max
    end
  end

  def self.daily_reset(provider, failed_at)
    return failed_at + 1.day unless provider.to_s == GeminiService.provider_key

    failed_at.in_time_zone(GEMINI_RESET_ZONE).tomorrow.beginning_of_day
  end
end
