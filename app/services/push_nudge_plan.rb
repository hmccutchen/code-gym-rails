# Whether this tick warrants a "you haven't started today's set" nudge.
#
# Pure: it takes facts rather than records, so its specs need no database —
# the property DailyPlan's collaborators keep. The existence of today's
# exercise is the caller's precondition, not a parameter: due? is only reached
# from the branch that has already established the row exists.
class PushNudgePlan
  # Local hours, inclusive. The window is a pure function of the current hour,
  # so it needs no timestamp column and cannot drift.
  #
  # What it deliberately does NOT do is bound how many nudges a user receives:
  # due? re-decides on every tick and holds no dedupe, so the count is ticks
  # per hour times the window's length. Production ticks hourly
  # (config/recurring.yml), which is what makes it five. Change that schedule
  # and you change the volume.
  NUDGE_HOURS = (13..17)

  def self.due?(level:, hour:, started:, submitted:)
    level.to_s == "ready_and_nudges" &&
      NUDGE_HOURS.cover?(hour) &&
      !started &&
      !submitted
  end

  # Rendered into the Account page's opt-in label, so the user is told the
  # window they are agreeing to and it can only ever come from the constant.
  def self.window_description
    format = ->(hour) { Time.zone.parse("#{hour}:00").strftime("%-l%P") }

    "#{format.call(NUDGE_HOURS.min)}–#{format.call(NUDGE_HOURS.max)}"
  end
end
