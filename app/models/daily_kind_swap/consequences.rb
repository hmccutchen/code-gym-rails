# Design notes: docs/code-notes/app/models/daily_kind_swap/consequences.md
class DailyKindSwap::Consequences
  WEEKDAYS_PER_WEEK = 5

  Result = Data.define(:sentences, :warning)

  def self.for(pair:, place:, kind:, preferences:, setting:, planned_size:, languages:)
    new(pair: pair, place: place, kind: kind, preferences: preferences, setting: setting,
        planned_size: planned_size, languages: languages).result
  end

  def initialize(pair:, place:, kind:, preferences:, setting:, planned_size:, languages:)
    @pair         = pair
    @kind         = kind
    @outgoing     = pair[place]
    @proposed     = pair.dup.tap { |kinds| kinds[place] = kind }
    @preferences  = preferences
    @setting      = setting
    @planned_size = planned_size
    @languages    = languages
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
    line(:shared_concept) if can_share?(@pair) && !can_share?(@proposed)
  end

  def stored_weight
    multiplier = @preferences.multiplier_for(@kind)
    return if multiplier == KindPreferences::DEFAULT_MULTIPLIER

    line(multiplier > KindPreferences::DEFAULT_MULTIPLIER ? :weight_more : :weight_less, kind: name(@kind))
  end

  def stored_exclusion
    line(:excluded_incoming, kind: name(@kind)) if @preferences.excluded?(@kind)
  end

  # Suppression outranks size: neither a larger day nor coverage brings back a kind D1 or an exclusion keeps out.
  def warning
    return [ line(:outgoing_one_fourth, outgoing: name(@outgoing), kind: name(@kind)) ] if @outgoing.fourth? && @kind.fourth?
    return [ outgoing_excluded ] if rotation_skips_outgoing?
    return [] unless two_sections?
    return [ line(:outgoing_fixed_two, outgoing: name(@outgoing)) ] if @setting == DailyKinds::COUNT
    return [ outgoing_excluded ] if @preferences.excluded?(@outgoing)

    [ line(:outgoing_weeks, outgoing: name(@outgoing), weeks: coverage_weeks), line(:outgoing_gate) ]
  end

  def outgoing_excluded = line(:outgoing_excluded, outgoing: name(@outgoing))

  def rotation_skips_outgoing?
    group = ExerciseSection.optional_slots(daily: @proposed).values.find { |kinds| kinds.include?(@outgoing) }
    @preferences.excluded?(@outgoing) && group.present? && @preferences.eligible(group).exclude?(@outgoing)
  end

  def two_sections?
    return @setting == DailyKinds::COUNT if @setting

    @planned_size == DailyKinds::COUNT
  end

  # Coverage adds at most one kind per CAP_WEEKDAYS + 1 weekdays, each unseen past GAP_WEEKDAYS, so the kinds take turns.
  def coverage_weeks
    candidates = ExerciseSection.optional_slots(daily: @proposed).values.flatten.count { |kind| !@preferences.excluded?(kind) }
    weekdays   = [ CoverageException::GAP_WEEKDAYS + 1, (CoverageException::CAP_WEEKDAYS + 1) * candidates ].max

    (weekdays.to_f / WEEKDAYS_PER_WEEK).round
  end

  def can_share?(pair)
    @languages.product(DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys).any? do |language, mode|
      hosts  = DayHosts.new(language, mode: mode)
      bucket = ConceptBucket.for(pair.first.key, language)
      ConceptVocabulary.selectable_for_section(pair.first.key, language, mode: mode)
        .any? { |concept| pair.all? { |kind| hosts.can_tag?(kind, concept, bucket) } }
    end
  end

  def line(key, **values) = I18n.t("daily_kinds.picker.consequences.#{key}", **values)

  def name(kind) = I18n.t("sections.#{kind.key}.name")

  def names(kinds) = kinds.map { |kind| name(kind) }.to_sentence(last_word_connector: " and ")
end
