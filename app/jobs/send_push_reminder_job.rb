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

  def perform(user_id:, kind: :ready)
    return unless WebPushCredentials.configured?

    user = User.active.find_by(id: user_id)
    return unless user
    return unless wanted?(user, kind)

    Time.use_zone(user.effective_time_zone) do
      exercise = user.daily_exercises.for_date(Date.current).first
      return unless exercise
      return if already_submitted?(user, exercise)

      deliver_to_each_endpoint(user, exercise, kind)
    end
  end

  private

  # Re-asked here rather than trusted from the caller, for the same reason the
  # scope used to sit in this job: it is enqueued asynchronously and the level
  # can move between enqueue and run. An unknown kind falls through to nil and
  # sends nothing.
  def wanted?(user, kind)
    case kind.to_sym
    when :ready then !user.reminders_none?
    when :nudge then user.reminders_ready_and_nudges?
    end
  end

  # Nothing to nudge someone toward if they have already finished it — the set
  # can exist and be done before this runs, since generation and delivery are
  # separate jobs and the second can be queued behind a slow first.
  def already_submitted?(user, exercise)
    user.daily_responses.submitted.exists?(daily_exercise: exercise)
  end

  def deliver_to_each_endpoint(user, exercise, kind)
    title = title_for(kind)
    body  = body_for(exercise, kind)

    user.push_subscriptions.each do |subscription|
      PushDelivery.deliver(subscription, title: title, body: body, path: "/")
    end
  end

  def title_for(kind)
    kind.to_sym == :nudge ? "Today's set is still waiting" : "Today's Code Gym is ready"
  end

  # active_section_keys is the authority for how many sections a day has; the
  # count is never recomputed from problem_set.keys here or anywhere else.
  def body_for(exercise, kind)
    count    = exercise.active_section_keys.size
    sections = "#{count} #{'section'.pluralize(count)}"

    return "#{sections} waiting." unless kind.to_sym == :nudge

    "#{sections} · about #{hours_left_today}h left today."
  end

  # Whole hours to local midnight — the boundary that actually breaks a streak,
  # unlike "time until the next set", which reads as two days every Friday.
  # No sub-hour branch: NUDGE_HOURS ends at 17, so the minimum is about six
  # hours, and a spec pins that relationship rather than a comment asserting it.
  def hours_left_today
    ((Time.current.end_of_day - Time.current) / 1.hour).floor
  end
end
