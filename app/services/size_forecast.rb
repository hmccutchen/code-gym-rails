# Whether tomorrow's Automatic set will differ in size from the set today's
# plan delivered, for the dashboard's submitted state. Composes tomorrow's
# size the way DailyPlan will, with today's submission and review already
# counted.
class SizeForecast
  Change = Data.define(:direction, :count)

  # A size today's fixed setting chose says nothing about the engineer's
  # answers, so a switch to Automatic is never credited to them.
  def self.for(user, exercise)
    return nil unless user.daily_section_count.nil? && exercise.planned_size && !exercise.planned_by_setting?

    history = user.recent_exercise_history(limit: SectionRotation::LOOKBACK, before: exercise.date.next_day)
    change(exercise.planned_size_with_coverage, DailyPlan.size_for(user, history))
  end

  # Larger whenever the composed size grows, so a gate increase completion
  # still blocks never promises one. Smaller only when the brake is what
  # lowers it, since that is the reason the line gives.
  def self.change(today, tomorrow)
    return Change.new(direction: :larger, count: tomorrow.count) if tomorrow.count > today

    Change.new(direction: :smaller, count: tomorrow.count) if tomorrow.reason == :brake && tomorrow.count < today
  end
end
