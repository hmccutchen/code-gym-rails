# Whether this tick warrants a "today's set isn't finished" nudge.
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

  # How long the last save holds a nudge off. The stopping rule is submission,
  # so a half-answered set goes on qualifying all afternoon — which without
  # this would tell someone still typing that they haven't finished. Compared
  # against an absolute timestamp rather than the local hour the window uses,
  # so it needs no zone of its own.
  #
  # One hour covers a whole tick of the production schedule, so a save silences
  # the next nudge whatever minute it landed on. A shorter period would not:
  # a save early in the gap between two ticks would still be past it by the
  # time the later one ran. push_nudge_plan_spec pins that against
  # config/recurring.yml rather than leaving it to this comment.
  QUIET_PERIOD = 1.hour

  # The half of the decision that needs no response row. Callers use it to
  # avoid a query they would only throw away — the cron before loading the
  # day's response, since most users on any tick are at the wrong level or
  # outside the window. It is not a second statement of the rule: due? is
  # defined in terms of it, so there is still one place the level and the
  # window are decided.
  def self.possible?(level:, hour:)
    level.to_s == "ready_and_nudges" && NUDGE_HOURS.cover?(hour)
  end

  # Unfinished, and quiet for long enough that the reminder isn't interrupting
  # the work it asks for. Submission is the whole stopping rule — a day with
  # two of three sections answered is exactly what this exists to reach, so
  # having started is no longer an answer. `last_activity_at` is the day's
  # response row's own timestamp, nil until the first answer is saved.
  def self.due?(level:, hour:, submitted:, last_activity_at:)
    possible?(level: level, hour: hour) && !submitted && quiet?(last_activity_at)
  end

  def self.quiet?(last_activity_at)
    last_activity_at.nil? || last_activity_at <= QUIET_PERIOD.ago
  end
  private_class_method :quiet?

  # Rendered into the Account page's opt-in label, so the user is told the
  # window they are agreeing to and it can only ever come from the constant.
  def self.window_description
    format = ->(hour) { Time.zone.parse("#{hour}:00").strftime("%-l%P") }

    "#{format.call(NUDGE_HOURS.min)}–#{format.call(NUDGE_HOURS.max)}"
  end
end
