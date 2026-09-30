class TrackGraduation
  FORWARD_WINDOW = 3
  STRUGGLE_WINDOW = 3
  STRUGGLE_THRESHOLD = 2

  NEXT_LEVEL = { LearningTrack::START_LEVEL => LearningTrack::GRADUATED_LEVEL }.freeze
  PREVIOUS_LEVEL = NEXT_LEVEL.invert.freeze

  Result = Data.define(:date, :level, :ai_rating, :self_rating) do
    def favourable?
      DailyResponse::AI_RATING_FAVORABLE.include?(ai_rating) &&
        DailyResponse::SELF_RATING_FAVORABLE.include?(self_rating)
    end

    def too_hard? = self_rating == "too_hard"
  end

  Step = Data.define(:kind, :from, :to, :results_at_level)
  Proposal = Data.define(:basis, :steps)

  def self.proposal(levels:, locked:, results:, cutoffs:)
    new(levels: levels, locked: locked, results: results, cutoffs: cutoffs).proposal
  end

  def initialize(levels:, locked:, results:, cutoffs:)
    @levels = levels
    @locked = locked
    @results = results
    @cutoffs = cutoffs
    @lead = ExerciseSection.learning_track_lead.key
  end

  def proposal
    single(:struggling) { |key| back_step(key) } ||
      single(:own) { |key| own_step(key) } ||
      led_bundle
  end

  private

  def single(basis)
    step = candidates.lazy.filter_map { |key| yield key }.first
    step && Proposal.new(basis: basis, steps: [ step ])
  end

  def led_bundle
    steps = candidates.filter_map { |key| led_step(key) }
    Proposal.new(basis: :led, steps: steps) if steps.any?
  end

  def candidates
    ExerciseSection.keys.select { |key| LearningTrack::LEVELS.include?(@levels[key]) && @locked.exclude?(key) }
  end

  def back_step(key)
    level = @levels[key]
    return unless PREVIOUS_LEVEL.key?(level)

    at_level = evidence_at(key, level)
    return unless at_level.first(STRUGGLE_WINDOW).count(&:too_hard?) >= STRUGGLE_THRESHOLD

    Step.new(kind: key, from: level, to: PREVIOUS_LEVEL[level], results_at_level: at_level.size)
  end

  def own_step(key)
    level = @levels[key]
    return unless NEXT_LEVEL.key?(level)

    at_level = evidence_at(key, level)
    return unless full_favourable_window?(at_level)

    Step.new(kind: key, from: level, to: NEXT_LEVEL[level], results_at_level: at_level.size)
  end

  def led_step(key)
    level = @levels[key]
    return if key == @lead || !NEXT_LEVEL.key?(level) || !lead_past?(level)

    at_level = evidence_at(key, level)
    return unless at_level.first(FORWARD_WINDOW).all?(&:favourable?)
    return if cut_off_through(key) && !full_favourable_window?(since_cutoff(key, @results.fetch(@lead, [])))

    Step.new(kind: key, from: level, to: NEXT_LEVEL[level], results_at_level: at_level.size)
  end

  def lead_past?(level)
    lead_rank = KindDifficulty::LEVELS.index(@levels[@lead])
    lead_rank.present? && lead_rank > KindDifficulty::LEVELS.index(level)
  end

  def full_favourable_window?(results)
    window = results.first(FORWARD_WINDOW)
    window.size == FORWARD_WINDOW && window.all?(&:favourable?)
  end

  def evidence_at(key, level)
    since_cutoff(key, @results.fetch(key, []).select { |result| result.level == level })
  end

  def since_cutoff(key, results)
    through = cut_off_through(key)
    through ? results.select { |result| result.date > through } : results
  end

  def cut_off_through(key)
    entry = @cutoffs[key]
    return unless entry.is_a?(Hash) && entry["level"] == @levels[key]

    Date.iso8601(entry["through"].to_s)
  rescue Date::Error
    nil
  end
end
