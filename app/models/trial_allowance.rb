# Re-checks the trial is active, since a service built during it keeps the house key through fan-outs and long jobs.
class TrialAllowance
  def self.check!(user, provider:, now: Time.current)
    new(user, provider, now).check!
  end

  def initialize(user, provider, now)
    @user     = user
    @provider = provider
    @now      = now
  end

  def check!
    check_trial_active!
    check_account_cap!
    check_house_guard!
  end

  private

  def check_trial_active!
    raise AiService::TrialEndedError, "Trial ended for user #{@user.id}" unless @user.trial_active?(now: @now)
  end

  def check_account_cap!
    cap = @user.invite_code&.daily_request_cap
    return unless cap

    local = @now.in_time_zone(@user.effective_time_zone)
    return if ApiUsage.requests_on(@user, local.to_date, provider: @provider.provider_key) < cap

    refuse("Trial account cap reached for user #{@user.id}", resets_at: local.tomorrow.beginning_of_day)
  end

  def check_house_guard!
    guard = HouseKeys.daily_guard_for(@provider.provider_key)
    return unless guard

    day = @provider.quota_day(@now)
    return if ApiUsage.house_requests_between(provider: @provider.provider_key, from: day.begin, to: day.end) < guard

    refuse("House key guard reached for #{@provider.provider_key}", resets_at: day.end)
  end

  def refuse(message, resets_at:)
    raise AiService::TrialAllowanceError.new(message, retry_after: (resets_at - @now).ceil)
  end
end
