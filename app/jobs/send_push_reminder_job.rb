# The daily reminders, fanned out over one user's push endpoints.
#
# Two kinds, one job. :ready is enqueued by GenerateDailyExercisesJob's cron
# branch on the tick that generates the set — "it is this user's 8am on a
# weekday" is a rule that already has an owner, and a second cron entry would
# be a second place for it to drift. :nudge is enqueued from that same branch
# on later ticks, gated by PushNudgePlan. The on-demand branch sends neither:
# someone who triggered generation by opening the dashboard is already looking
# at the set this would tell them about.
class SendPushReminderJob < ApplicationJob
  queue_as :default

  # How a nudge addresses each unfinished state. The copy has to be right for
  # someone two-thirds through, not only for someone who never opened the set —
  # telling them it is "still waiting" is how a reminder starts reading as
  # something that hasn't noticed the work. :unrated is its own state rather
  # than part of :unsubmitted because the dashboard keeps Submit disabled until
  # every section is rated, so calling that set ready to submit would name a
  # button the user cannot press.
  NUDGE_TITLES = {
    untouched:   "Today's set is still waiting",
    partway:     "You're partway through today's set",
    unrated:     "Today's set just needs its difficulty ratings",
    unsubmitted: "Today's set is ready to submit"
  }.freeze

  def perform(user_id:, kind: :ready)
    return unless WebPushCredentials.configured?

    user = User.active.find_by(id: user_id)
    return unless user

    Time.use_zone(user.effective_time_zone) do
      exercise = user.daily_exercises.for_date(Date.current).first
      return unless exercise

      # Nothing to remind someone about if they have already finished it — the
      # set can exist and be done before this runs, since generation and
      # delivery are separate jobs and the second can be queued behind a slow
      # first.
      response = user.daily_responses.find_by(daily_exercise: exercise)
      return if response&.submitted?
      return unless still_wanted?(user, response, kind)

      deliver_to_each_endpoint(user, exercise, response, kind)
    end
  end

  private

  # Decided here at run time rather than trusted from the enqueue, because
  # every fact behind it can move in between: the level, how much of the day
  # has been answered, and — under a queue backlog — the hour itself. Without
  # this a nudge queued at five could arrive near midnight telling someone who
  # was still working at six that they have sections left. Inside
  # Time.use_zone, so the hour is the user's own. An unknown kind falls through
  # to nil and sends nothing.
  def still_wanted?(user, response, kind)
    case kind.to_sym
    when :ready then !user.reminders_none?
    when :nudge then nudge_still_due?(user, response)
    end
  end

  # PushNudgePlan stays the only place the nudge rule lives; this re-asks it
  # with what is true now instead of what was true at enqueue.
  def nudge_still_due?(user, response)
    PushNudgePlan.due?(
      level:            user.reminder_level,
      hour:             Time.current.hour,
      submitted:        response&.submitted?,
      last_activity_at: response&.updated_at
    )
  end

  def deliver_to_each_endpoint(user, exercise, response, kind)
    stage = stage_for(exercise, response)
    title = title_for(kind, stage)
    body  = body_for(kind, exercise, response, stage)

    user.push_subscriptions.each do |subscription|
      PushDelivery.deliver(subscription, title: title, body: body, path: "/")
    end
  end

  # How far through an unfinished day the user is. Reached only once submission
  # has been ruled out, so :unsubmitted means every section is answered and
  # rated and the Submit button is all that is left. A non-zero answered count
  # guarantees a response row, so #submittable? is only ever asked of one.
  def stage_for(exercise, response)
    answered = answered_count(response)

    return :untouched if answered.zero?
    return :partway   if answered < section_count(exercise)
    return :unrated   unless response.submittable?

    :unsubmitted
  end

  def title_for(kind, stage)
    return "Today's Code Gym is ready" unless kind.to_sym == :nudge

    NUDGE_TITLES.fetch(stage)
  end

  def body_for(kind, exercise, response, stage)
    return "#{sections_phrase(exercise)} waiting." unless kind.to_sym == :nudge

    "#{progress_phrase(exercise, response, stage)} · about #{hours_left_today}h left today."
  end

  def progress_phrase(exercise, response, stage)
    total = section_count(exercise)

    case stage
    when :untouched then sections_phrase(exercise)
    when :partway   then "#{total - answered_count(response)} of #{total} #{'section'.pluralize(total)} still to go"
    else                 "All #{total} #{'section'.pluralize(total)} answered"
    end
  end

  def sections_phrase(exercise)
    count = section_count(exercise)

    "#{count} #{'section'.pluralize(count)}"
  end

  # active_section_keys is the authority for how many sections a day has; the
  # count is never recomputed from problem_set.keys here or anywhere else.
  # #answered_sections counts against those same keys, so the two can't
  # disagree and the remainder can never come out negative.
  def section_count(exercise) = exercise.active_section_keys.size
  def answered_count(response) = response ? response.answered_sections.size : 0

  # Whole hours to local midnight — the boundary that actually breaks a streak,
  # unlike "time until the next set", which reads as two days every Friday.
  # No sub-hour branch: NUDGE_HOURS ends at 17, so the minimum is about six
  # hours, and a spec pins that relationship rather than a comment asserting it.
  def hours_left_today
    ((Time.current.end_of_day - Time.current) / 1.hour).floor
  end
end
