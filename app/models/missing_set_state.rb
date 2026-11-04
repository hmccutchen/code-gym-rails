module MissingSetState
  def self.for(trial_ended:, provider_ready:, manual_trigger:, failed_today:, weekend:, paused:)
    return :trial_ended if trial_ended
    return :awaiting_provider unless provider_ready
    # A fresh manual trigger outranks a failure recorded earlier today.
    return :generating if manual_trigger
    return :generation_failed if failed_today
    # Ahead of the pause: a weekend is empty either way, so naming the pause would mislead.
    return :weekend if weekend
    return :paused if paused

    :start_generation
  end
end
