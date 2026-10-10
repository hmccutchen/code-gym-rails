# Callers must establish today's exercise exists before asking due?.
class PushNudgePlan
  # No dedupe here: nudge volume is ticks per hour times the window, so changing config/recurring.yml changes it.
  NUDGE_HOURS = (13..17)

  # One hour covers a whole hourly tick, so any save silences the next nudge; push_nudge_plan_spec pins the schedule.
  QUIET_PERIOD = 1.hour

  # Lets the cron skip loading the response; due? is defined through it, so the rule still lives in one place.
  def self.possible?(level:, hour:)
    level.to_s == "ready_and_nudges" && NUDGE_HOURS.cover?(hour)
  end

  # Submission is the whole stopping rule; last_activity_at is the response's updated_at, nil before any save.
  def self.due?(level:, hour:, submitted:, last_activity_at:)
    possible?(level: level, hour: hour) && !submitted && quiet?(last_activity_at)
  end

  def self.quiet?(last_activity_at)
    last_activity_at.nil? || last_activity_at <= QUIET_PERIOD.ago
  end
  private_class_method :quiet?

  # Shown in the Account opt-in label, so the stated window always comes from the constant.
  def self.window_description
    format = ->(hour) { Time.zone.parse("#{hour}:00").strftime("%-l%P") }

    "#{format.call(NUDGE_HOURS.min)}–#{format.call(NUDGE_HOURS.max)}"
  end
end
