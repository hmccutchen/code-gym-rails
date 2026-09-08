# Whether this tick warrants a "you haven't started today's set" nudge.
#
# Pure: it takes facts rather than records, so its specs need no database —
# the property DailyPlan's collaborators keep. The existence of today's
# exercise is the caller's precondition, not a parameter: due? is only reached
# from the branch that has already established the row exists.
class PushNudgePlan
  # Local hours, inclusive — five nudges at most, and only on a day the user
  # never touched. A window that is a pure function of the current hour needs
  # no timestamp column and so cannot drift out of step with the cron tick.
  NUDGE_HOURS = (13..17)

  def self.due?(level:, hour:, started:, submitted:)
    level.to_s == "ready_and_nudges" &&
      NUDGE_HOURS.cover?(hour) &&
      !started &&
      !submitted
  end
end
