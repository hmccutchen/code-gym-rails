class SizeForecast
  Change = Data.define(:direction, :count)

  # A size a fixed setting chose says nothing about the engineer's answers, so switching to Automatic earns no credit.
  def self.for(user, exercise)
    return nil unless user.daily_section_count.nil? && exercise.planned_size && !exercise.planned_by_setting?

    history = user.recent_exercise_history(limit: SectionRotation::LOOKBACK, before: exercise.date.next_day)
    change(delivered_or_planned(exercise), DailyPlan.size_for(user, history))
  end

  # Ingest can keep an unrequested extra and the judge can drop one, so take the larger of planned and shown.
  def self.delivered_or_planned(exercise)
    [ exercise.planned_size_with_coverage, exercise.active_section_keys.size ].max
  end
  private_class_method :delivered_or_planned

  # Smaller only when the brake lowers it, since the brake is the reason the dashboard line gives.
  def self.change(today, tomorrow)
    return Change.new(direction: :larger, count: tomorrow.count) if tomorrow.count > today

    Change.new(direction: :smaller, count: tomorrow.count) if tomorrow.reason == :brake && tomorrow.count < today
  end
end
