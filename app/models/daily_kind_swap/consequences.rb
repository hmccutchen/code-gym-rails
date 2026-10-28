# Design notes: docs/code-notes/app/models/daily_kind_swap/consequences.md
class DailyKindSwap::Consequences
  WEEKDAYS_PER_WEEK = 5

  Result = Data.define(:sentences, :warning)

  # held is how many places the user's setting fills with daily kinds.
  Day = Data.define(:setting, :planned_size, :brake, :held)

  def self.for(pair:, place:, kind:, preferences:, day:, languages:, pair_shares:)
    new(pair: pair, place: place, kind: kind, preferences: preferences, day: day,
        languages: languages, pair_shares: pair_shares).result
  end

  def self.shares_a_concept?(pair, languages)
    languages.product(DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys).any? do |language, mode|
      hosts  = DayHosts.new(language, mode: mode)
      bucket = ConceptBucket.for(pair.first.key, language)
      ConceptVocabulary.selectable_for_section(pair.first.key, language, mode: mode)
        .any? { |concept| pair.all? { |kind| hosts.can_tag?(kind, concept, bucket) } }
    end
  end

  def initialize(pair:, place:, kind:, preferences:, day:, languages:, pair_shares:)
    @kind        = kind
    @outgoing    = pair[place]
    @proposed    = pair.dup.tap { |kinds| kinds[place] = kind }
    @preferences = preferences
    @day         = day
    @languages   = languages
    @pair_shares = pair_shares
  end

  def result = Result.new(sentences: sentences, warning: warning)

  private

  def sentences
    [ fourth_siblings, shared_concept, stored_weight, stored_exclusion ].compact
  end

  def fourth_siblings
    return unless @kind.fourth?

    line(:fourth_siblings, siblings: names(ExerciseSection.fourths - [ @kind ]), kind: name(@kind))
  end

  def shared_concept
    line(:shared_concept) if @pair_shares && !self.class.shares_a_concept?(@proposed, @languages)
  end

  def stored_weight
    multiplier = @preferences.multiplier_for(@kind)
    return if multiplier == KindPreferences::DEFAULT_MULTIPLIER

    line(multiplier > KindPreferences::DEFAULT_MULTIPLIER ? :weight_more : :weight_less, kind: name(@kind))
  end

  def stored_exclusion
    line(:excluded_incoming, kind: name(@kind)) if @preferences.excluded?(@kind)
  end

  # Suppression outranks size: neither a larger day nor coverage brings back a kind a daily fourth or an exclusion keeps out.
  def warning
    return [ line(:outgoing_one_fourth, outgoing: name(@outgoing), kind: name(@kind)) ] if @outgoing.fourth? && @kind.fourth?
    return [ outgoing_excluded ] if rotation_skips_outgoing?
    return [ line(:outgoing_fixed, count: @day.setting, outgoing: name(@outgoing)) ] if fixed_without_rotation?
    return [] unless coverage_day?(brake: false)
    return [ outgoing_excluded ] if @preferences.excluded?(@outgoing)
    return [ line(:outgoing_braked, outgoing: name(@outgoing)), line(:outgoing_gate) ] unless coverage_day?(brake: @day.brake)

    [ line(:outgoing_weeks, outgoing: name(@outgoing), weeks: coverage_weeks), line(:outgoing_gate) ]
  end

  def outgoing_excluded = line(:outgoing_excluded, outgoing: name(@outgoing))

  def fixed_without_rotation? = !@day.setting.nil? && @day.setting <= @day.held

  def rotation_skips_outgoing?
    group = ExerciseSection.optional_slots(daily: @proposed).values.find { |kinds| kinds.include?(@outgoing) }
    group.present? && !@preferences.eligible(group).include?(@outgoing)
  end

  def coverage_day?(brake:)
    @day.planned_size.present? &&
      CoverageException.applies_to_day?(count: @day.planned_size, fixed: @day.setting, brake: brake)
  end

  def coverage_weeks
    candidates = CoverageException.candidate_kinds(daily: @proposed, preferences: @preferences).size

    (CoverageException.expected_gap_weekdays(candidates: candidates).to_f / WEEKDAYS_PER_WEEK).round
  end

  def line(key, **values) = I18n.t("daily_kinds.picker.consequences.#{key}", **values)

  def name(kind) = I18n.t("sections.#{kind.key}.name")

  def names(kinds) = kinds.map { |kind| name(kind) }.to_sentence(last_word_connector: " and ")
end
