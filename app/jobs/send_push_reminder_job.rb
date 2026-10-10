# Enqueued only from GenerateDailyExercisesJob's cron branch, which already owns "8am on a weekday".
class SendPushReminderJob < ApplicationJob
  queue_as :default

  def perform(user_id:, kind: :ready)
    return unless WebPushCredentials.configured?

    user = User.active.find_by(id: user_id)
    return unless user

    Time.use_zone(user.effective_time_zone) do
      exercise = user.daily_exercises.for_date(Date.current).first
      return unless exercise

      # Generation and delivery are separate jobs, so the set can be finished before this runs.
      response = user.daily_responses.find_by(daily_exercise: exercise)
      return if response&.submitted?
      return unless still_wanted?(user, response, kind)

      deliver_to_each_endpoint(user, exercise, response, kind)
    end
  end

  private

  # Re-decided at run time because a queue backlog can move the level, the answers and the hour.
  def still_wanted?(user, response, kind)
    case kind.to_sym
    when :ready then !user.reminders_none?
    when :nudge then nudge_still_due?(user, response)
    end
  end

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

  # :unrated is its own stage because Submit stays disabled until every answered section is rated.
  def stage_for(exercise, response)
    answered = answered_count(response)

    return :untouched if answered.zero?
    return :unsubmitted if response.submittable?
    return :partway   if answered < section_count(exercise)

    :unrated
  end

  def title_for(kind, stage)
    return I18n.t("push_reminder.ready.title", app_name: I18n.t("app_name")) unless kind.to_sym == :nudge

    I18n.t("push_reminder.nudge.titles.#{stage}", raise: true)
  end

  def body_for(kind, exercise, response, stage)
    return I18n.t("push_reminder.ready.body", count: section_count(exercise)) unless kind.to_sym == :nudge

    I18n.t("push_reminder.nudge.body", progress: progress_phrase(exercise, response, stage), hours: hours_left_today)
  end

  def progress_phrase(exercise, response, stage)
    total = section_count(exercise)
    remaining = total - answered_count(response)
    return I18n.t("push_reminder.nudge.progress.optional_left", count: remaining) if stage == :unsubmitted && remaining.positive?

    case stage
    when :untouched then I18n.t("push_reminder.nudge.progress.untouched", count: total)
    when :partway   then I18n.t("push_reminder.nudge.progress.partway", count: total, remaining: remaining)
    else                 I18n.t("push_reminder.nudge.progress.all_answered", count: total)
    end
  end

  # active_section_keys is the authority for a day's section count; never count problem_set.keys.
  def section_count(exercise) = exercise.active_section_keys.size
  def answered_count(response) = response ? response.answered_sections.size : 0

  # Hours to local midnight, which is what breaks a streak; a spec pins that NUDGE_HOURS leaves several.
  def hours_left_today
    ((Time.current.end_of_day - Time.current) / 1.hour).floor
  end
end
