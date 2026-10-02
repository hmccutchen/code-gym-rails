# Whether tomorrow's Automatic set will differ in size from today's planned
# one, for the dashboard's submitted state. Composes tomorrow's size the way
# DailyPlan will, with today's submission and review already counted.
class SizeForecast
  def self.for(user, exercise)
    return nil unless user.daily_section_count.nil? && exercise.planned_size

    history = user.recent_exercise_history(limit: SectionRotation::LOOKBACK, before: exercise.date.next_day)
    change(exercise.planned_size, DailyPlan.size_for(user, history))
  end

  # Larger whenever the composed size grows, so a gate increase completion
  # still blocks never promises one. Smaller only when the brake is what
  # lowers it, since that is the reason the line gives.
  def self.change(planned_today, tomorrow)
    return :larger if tomorrow.count > planned_today

    :smaller if tomorrow.reason == :brake && tomorrow.count < planned_today
  end
end
