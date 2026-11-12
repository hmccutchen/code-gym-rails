# Design notes: docs/decisions/pausing-generation.md
module GenerationPause
  extend ActiveSupport::Concern

  GENERATION_PAUSE_SOURCES = %w[manual automatic].freeze
  MANUAL_PAUSE, AUTOMATIC_PAUSE = GENERATION_PAUSE_SOURCES

  def paused_generation_at? = paused_generation_at.present?

  def generation_pause_kind
    return nil unless paused_generation_at?

    generation_pause_source == AUTOMATIC_PAUSE ? AUTOMATIC_PAUSE : MANUAL_PAUSE
  end

  def generation_paused_automatically? = generation_pause_kind == AUTOMATIC_PAUSE

  def pause_generation!(source:)
    raise ArgumentError, "unknown pause source: #{source.inspect}" unless GENERATION_PAUSE_SOURCES.include?(source)

    with_lock do
      next keep_generation_paused(source) if paused_generation_at?

      update!(paused_generation_at: Time.current, generation_pause_source: source)
      :paused
    end
  end

  def pause_for_unopened_sets!
    with_lock do
      today = today_in_own_zone
      due = !daily_exercises.for_date(today).exists? && UnopenedSets.pause?(daily_exercises.latest_openings, today: today)
      due ? pause_generation!(source: AUTOMATIC_PAUSE) : :running
    end
  end

  def clear_generation_pause!
    with_lock do
      daily_exercises.acknowledge_unopened!(today: today_in_own_zone) if paused_generation_at?
      update!(paused_generation_at: nil, generation_pause_source: nil)
    end
  end

  private

  def today_in_own_zone = Time.current.in_time_zone(effective_time_zone).to_date

  # The pause time is User#held_exercise's floor, so a repeated pause changes the source at most.
  def keep_generation_paused(source)
    update!(generation_pause_source: MANUAL_PAUSE) if source == MANUAL_PAUSE && generation_pause_source != MANUAL_PAUSE
    :kept
  end
end
