module ExplainQuestion
  PHRASINGS = %w[explain.first explain.second explain.third].freeze
  RECENT_DAYS = 7

  Option = Data.define(:section, :concept, :sections)

  def self.options(tags:)
    tags.each_with_object([]) do |(section, concept), options|
      next if concept.nil?

      index = options.index { |held| held.concept == concept }
      if index
        options[index] = options[index].with(sections: options[index].sections + [ section ])
      else
        options << Option.new(section: section, concept: concept, sections: [ section ])
      end
    end
  end

  def self.default(options:, duck_turns:, cleared:, too_hard:, recent:)
    fresh = options.reject { |option| recent.include?(option.concept) }
    candidates = fresh.empty? ? options : fresh
    signals = candidates.map { |option| signal(option, duck_turns, cleared, too_hard) }
    signalled = candidates.each_index.select { |index| signals[index] }
    return candidates.first if signalled.empty?

    candidates[signalled.min_by { |index| [ *signals[index], index ] }]
  end

  def self.phrasing(earlier_explanations) = PHRASINGS[earlier_explanations.clamp(0, PHRASINGS.size - 1)]

  def self.text(phrasing, concept) = I18n.t("learner_questions.#{phrasing}", concept: concept.humanize)

  # Sorts duck use ahead of a rating alone, then more user turns; nil when the option has neither signal.
  def self.signal(option, duck_turns, cleared, too_hard)
    turns = option.sections.sum { |section| duck_turns.fetch(section, 0) }
    duck_used = turns.positive? || option.sections.any? { |section| cleared.fetch(section, 0).positive? }
    return [ 0, -turns ] if duck_used

    [ 1, 0 ] if option.sections.any? { |section| too_hard.include?(section) }
  end
  private_class_method :signal
end
