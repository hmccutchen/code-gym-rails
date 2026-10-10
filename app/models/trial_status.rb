# Active also reads the kill switch and house key, as TrialAllowance does.
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

  def active? = @user.trial_active?(now: @now)

  def ends_on = @user.trial_ends_at.in_time_zone(@user.effective_time_zone).to_date

  # Today counts: a trial ending at the end of today has one day left.
  def days_left = [ (ends_on - @local.to_date).to_i + 1, 0 ].max

  # Nil when the trial ended early, under the kill switch or with no house key.
  def ended_on = @user.trial_ends_at <= @now ? ends_on : nil
end
