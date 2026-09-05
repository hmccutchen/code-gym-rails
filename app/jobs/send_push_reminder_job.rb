# The morning nudge, fanned out over one user's push endpoints.
#
# Enqueued by GenerateDailyExercisesJob's cron branch once a set exists, rather
# than run on a schedule of its own: "it is this user's 8am on a weekday" is a
# rule that already has an owner, and a second cron entry would be a second
# place for it to drift. The on-demand branch deliberately doesn't enqueue it —
# a user who triggered generation by opening the dashboard is already looking
# at the set this would tell them about.
class SendPushReminderJob < ApplicationJob
  queue_as :default

  def perform(user_id:)
    return unless WebPushCredentials.configured?

    user = User.active.where(push_reminders_enabled: true).find_by(id: user_id)
    return unless user

    Time.use_zone(user.effective_time_zone) do
      exercise = user.daily_exercises.for_date(Date.current).first
      return unless exercise
      return if already_submitted?(user, exercise)

      deliver_to_each_endpoint(user, exercise)
    end
  end

  private

  # Nothing to nudge someone toward if they have already finished it — the set
  # can exist and be done before this runs, since generation and delivery are
  # separate jobs and the second can be queued behind a slow first.
  def already_submitted?(user, exercise)
    user.daily_responses.submitted.exists?(daily_exercise: exercise)
  end

  def deliver_to_each_endpoint(user, exercise)
    user.push_subscriptions.each do |subscription|
      PushDelivery.deliver(
        subscription,
        title: "Today's Code Gym is ready",
        body:  body_for(exercise),
        path:  "/"
      )
    end
  end

  # active_section_keys is the authority for how many sections a day has; the
  # count is never recomputed from problem_set.keys here or anywhere else.
  def body_for(exercise)
    count = exercise.active_section_keys.size
    "#{count} #{'section'.pluralize(count)} waiting."
  end
end
