# Design notes: docs/code-notes/app/models/daily_kind_swap/consequences.md
class DailyKindSwap::Consequences
  Result = Data.define(:sentences, :warning)

  def self.for(pair:, place:, kind:, preferences:, practice_policy:)
    new(pair: pair, place: place, kind: kind, preferences: preferences, practice_policy: practice_policy).result
  end

  def initialize(pair:, place:, kind:, preferences:, practice_policy:)
    @kind        = kind
    @outgoing    = pair[place]
    @preferences = preferences
    @practice_policy = practice_policy
  end

  def result = Result.new(sentences: sentences, warning: warning)

  private

  def sentences
    [ fourth_siblings, stored_weight, stored_exclusion ].compact
  end

  def fourth_siblings
    return unless @kind.fourth?

    line(:fourth_siblings, siblings: names(ExerciseSection.fourths - [ @kind ]), kind: name(@kind))
  end

  def stored_weight
    multiplier = @preferences.multiplier_for(@kind)
    return if multiplier == KindPreferences::DEFAULT_MULTIPLIER

    line(multiplier > KindPreferences::DEFAULT_MULTIPLIER ? :weight_more : :weight_less, kind: name(@kind))
  end

  def stored_exclusion
    line(:excluded_incoming, kind: name(@kind)) if @preferences.excluded?(@kind)
  end

  def warning
    return [ I18n.t("protected_practice.unavailable") ] if @practice_policy == :unavailable
    return [ line(:outgoing_one_fourth, outgoing: name(@outgoing), kind: name(@kind)) ] if @outgoing.fourth? && @kind.fourth?
    return [ line(:outgoing_excluded, outgoing: name(@outgoing)) ] if @preferences.excluded?(@outgoing)

    [ I18n.t("protected_practice.daily_kinds.outgoing", outgoing: name(@outgoing)) ]
  end

  def line(key, **values) = I18n.t("daily_kinds.picker.consequences.#{key}", **values)

  def name(kind) = I18n.t("sections.#{kind.key}.name")

  def names(kinds) = kinds.map { |kind| name(kind) }.to_sentence(last_word_connector: " and ")
end
