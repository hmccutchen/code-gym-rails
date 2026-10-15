class LevelSuggestion
  # Principal is only ever set by hand, so senior is the top step and no suggestion leaves or reaches it.
  LADDER = (KindDifficulty::LEVELS - [ "principal_engineer" ]).freeze
  WINDOW = 5
  FAVOURABLE_NEEDED = 4
  VETO_WINDOW = 3
  VETO_TOO_HARD = 2
  STEP_BACK_WINDOW = 3
  STEP_BACK_TOO_HARD = 2
  IN_PLACE_ANSWERS = 3

  Result = Data.define(:date, :level, :ai_rating, :self_rating) do
    # The AI rating alone, unlike ReviewedSectionResults.favourable?: docs/code-notes/app/services/level_suggestion.md
    def ai_favourable? = ReviewedSectionResults.at_or_above?(ai_rating, ReviewedSectionResults::FAVOURABLE_BAR)
    def too_hard? = ReviewedSectionResults.too_hard?(self_rating)
  end

  Step = Data.define(:kind, :from, :to, :results_at_level, :favourable, :too_hard)
  Proposal = Data.define(:basis, :steps)
  Summary = Data.define(:window_size, :favourable, :too_hard_latest3, :newest_result_on)

  def self.for(user)
    proposal(levels: user.section_kind_levels, locked: user.locked_section_kinds,
             results: Evidence.for(user).results, cutoffs: user.track_evidence_cutoffs)
  end

  def self.proposal(levels:, locked:, results:, cutoffs:)
    new(levels: levels, locked: locked, results: results, cutoffs: cutoffs).proposal
  end

  def self.summary(kind:, level:, results:, cutoffs:)
    new(levels: { kind => level }, locked: [], results: results, cutoffs: cutoffs).summary(kind)
  end

  def self.cutoff_date(entry, level:)
    return unless entry.is_a?(Hash) && entry["level"] == level

    Date.iso8601(entry["through"].to_s)
  rescue Date::Error
    nil
  end

  def initialize(levels:, locked:, results:, cutoffs:)
    @levels = levels
    @locked = locked
    @results = results
    @cutoffs = cutoffs
  end

  def proposal
    struggling || own
  end

  def summary(key)
    at_level = evidence(key)
    window = at_level.first(WINDOW)
    Summary.new(window_size: window.size, favourable: window.count(&:ai_favourable?),
                too_hard_latest3: at_level.first(STEP_BACK_WINDOW).count(&:too_hard?),
                newest_result_on: at_level.first&.date)
  end

  private

  def struggling
    step = candidates.lazy.filter_map { |key| back_step(key) }.first
    step && Proposal.new(basis: :struggling, steps: [ step ])
  end

  # One card moves every kind it lists to the same level, so only the first qualifying kind's rung is offered.
  def own
    steps = candidates.filter_map { |key| up_step(key) }
    Proposal.new(basis: :own, steps: steps.select { |step| step.from == steps.first.from }) if steps.any?
  end

  def candidates
    ExerciseSection.keys.select { |key| LADDER.include?(@levels[key]) && @locked.exclude?(key) }
  end

  def up_step(key)
    rank = LADDER.index(@levels[key])
    return if rank == LADDER.size - 1

    at_level = evidence(key)
    window = at_level.first(WINDOW)
    too_hard = at_level.first(VETO_WINDOW).count(&:too_hard?)
    return unless window.size == WINDOW && window.count(&:ai_favourable?) >= FAVOURABLE_NEEDED && too_hard < VETO_TOO_HARD

    step(key, LADDER[rank + 1], at_level, too_hard)
  end

  # The engineer's too_hard proposes the move; AI ratings of solid or better on every one of them veto it.
  def back_step(key)
    rank = LADDER.index(@levels[key])
    return if rank.zero?

    at_level = evidence(key)
    hard = at_level.first(STEP_BACK_WINDOW).select(&:too_hard?)
    return if hard.size < STEP_BACK_TOO_HARD || hard.all?(&:ai_favourable?)

    step(key, LADDER[rank - 1], at_level, hard.size)
  end

  def step(key, to, at_level, too_hard)
    Step.new(kind: key, from: @levels[key], to: to, results_at_level: at_level.size,
             favourable: at_level.first(WINDOW).count(&:ai_favourable?), too_hard: too_hard)
  end

  def evidence(key)
    level = @levels[key]
    through = self.class.cutoff_date(@cutoffs[key], level: level)
    @results.fetch(key, []).select { |result| result.level == level && (through.nil? || result.date > through) }
  end
end
