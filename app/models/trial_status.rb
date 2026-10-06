# What a trial account is shown about its trial, in the user's zone and
# against the clock: how long is left, how much of today's cap is used, and
# when it ended. Pure over the user and the time it is given, except for the
# one usage count the gate also reads.
class TrialStatus
  attr_reader :used, :cap

  def self.for(user, now: Time.current) = new(user, now)

  def initialize(user, now)
    @user  = user
    @now   = now
    @local = now.in_time_zone(user.effective_time_zone)
    @cap   = user.invite_code&.daily_request_cap
    @used  = ApiUsage.requests_on(user, @local.to_date, provider: user.provider)
  end

  def active? = @user.trial_active?

  def ends_on = @user.trial_ends_at.in_time_zone(@user.effective_time_zone).to_date

  # Today counts: a trial ending at the end of today has one day left.
  def days_left = [ (ends_on - @local.to_date).to_i + 1, 0 ].max

  # Nil under the kill switch or with no house key, when the trial ended
  # without reaching its date.
  def ended_on = @user.trial_ends_at.past? ? ends_on : nil
end
