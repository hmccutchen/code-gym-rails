module StaleSetNotice
  NEWER_SET = { stale: "dashboard.stale_set.newer", replaced: "dashboard.stale_set.replaced" }.freeze

  RELOAD_STARTS_NOTHING = %i[weekend generation_failed trial_ended awaiting_provider].freeze

  def self.out_of_date(held_is_shown:, shown_submitted:, paused:, missing_set:)
    return "dashboard.stale_set.carried_forward" if paused && held_is_shown
    return "dashboard.stale_set.submitted" if shown_submitted
    return "dashboard.stale_set.paused" if paused
    return "dashboard.stale_set.starts_generation" if missing_set == :start_generation
    return "dashboard.stale_set.shows_today" if RELOAD_STARTS_NOTHING.include?(missing_set)

    raise ArgumentError, "No out-of-date sentence for #{missing_set.inspect}"
  end

  def self.newer_set(outcome) = NEWER_SET.fetch(outcome)
end
