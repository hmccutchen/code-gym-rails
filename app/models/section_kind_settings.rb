# Design notes: docs/code-notes/app/models/section_kind_settings.md
class SectionKindSettings
  FIELDS = %i[section_kind_weights excluded_section_kinds section_kind_levels locked_section_kinds daily_section_kinds].freeze

  def self.for(user)
    new(**FIELDS.index_with { |field| user.public_send(field) },
        stored: FIELDS.index_with { |field| user.attribute_in_database(field.to_s) })
  end

  def initialize(stored: {}, **values)
    @values = values
    @stored = stored
  end

  def changed?(*fields) = (fields.presence || FIELDS).any? { |field| @values[field] != @stored[field] }

  def problems
    [ *(weight_problems if changed?(:section_kind_weights)),
      *(exclusion_problems if changed?(:excluded_section_kinds)),
      *(emptied_slot_problems if changed?(:excluded_section_kinds, :daily_section_kinds)),
      *(daily_kind_problems if changed?(:daily_section_kinds)),
      *(level_problems if changed?(:section_kind_levels)),
      *(lock_problems if changed?(:locked_section_kinds)),
      *(locks_without_levels if changed?(:section_kind_levels, :locked_section_kinds)) ]
  end

  def emptied_slots(daily: self.daily)
    preferences = KindPreferences.new(weights: {}, excluded: Array(excluded))
    ExerciseSection.optional_slots(daily: daily).select do |_slot, kinds|
      kinds.size > 1 && preferences.all_excluded?(kinds)
    end
  end

  # attrs is a save's posted fields; each stored entry for a kind the current pair renders no control for is merged back in.
  def keep_unrendered(attrs)
    weighted = ExerciseSection.rotatable(daily: daily).map(&:key)
    shown    = ExerciseSection.pickable(daily: daily).map(&:key)
    keep_hidden(attrs, :section_kind_weights, weights.except(*weighted))
    keep_hidden(attrs, :excluded_section_kinds, excluded - weighted)
    keep_hidden(attrs, :section_kind_levels, levels.except(*shown))
    keep_hidden(attrs, :locked_section_kinds, locked - shown)
    attrs
  end

  def daily = DailyKinds.normalize(@values[:daily_section_kinds])

  private

  def weights = @values[:section_kind_weights]

  def excluded = @values[:excluded_section_kinds]

  def levels = @values[:section_kind_levels]

  def locked = @values[:locked_section_kinds]

  def rotatable_keys = ExerciseSection.rotatable(daily: daily).map(&:key)

  def weight_problems
    return [ [ :section_kind_weights, "must be an object" ] ] unless weights.is_a?(Hash)

    stored = @stored[:section_kind_weights].is_a?(Hash) ? @stored[:section_kind_weights] : {}
    weights.reject { |key, value| stored.key?(key) && stored[key] == value }.flat_map do |key, value|
      [ ([ :section_kind_weights, "names an unknown section kind: #{key}" ] if rotatable_keys.exclude?(key)),
        ([ :section_kind_weights, "has an unsupported weight for #{key}, which must be one of #{KindPreferences::MULTIPLIERS.join(', ')}" ] if KindPreferences::MULTIPLIERS.exclude?(value)) ].compact
    end
  end

  def exclusion_problems
    return [ [ :excluded_section_kinds, "must be a list" ] ] unless excluded.is_a?(Array)

    (excluded - Array(@stored[:excluded_section_kinds]) - rotatable_keys).map do |key|
      [ :excluded_section_kinds, "names an unknown section kind: #{key}" ]
    end
  end

  def emptied_slot_problems
    return [] unless excluded.is_a?(Array)

    emptied_slots.keys.map { |slot| [ :excluded_section_kinds, "must leave at least one #{slot} section in rotation" ] }
  end

  def daily_kind_problems
    DailyKinds.problems_with(@values[:daily_section_kinds]).map { |problem| [ :daily_section_kinds, problem ] }
  end

  def level_problems
    return [ [ :section_kind_levels, "must be an object" ] ] unless levels.is_a?(Hash)

    levels.flat_map do |key, value|
      [ ([ :section_kind_levels, "names an unknown section kind: #{key}" ] if ExerciseSection.keys.exclude?(key)),
        ([ :section_kind_levels, "has an unsupported level for #{key}, which must be one of #{KindDifficulty::LEVELS.join(', ')}" ] if KindDifficulty::LEVELS.exclude?(value)) ].compact
    end
  end

  def lock_problems
    return [ [ :locked_section_kinds, "must be a list" ] ] unless locked.is_a?(Array)

    (locked - ExerciseSection.keys).map { |key| [ :locked_section_kinds, "names an unknown section kind: #{key}" ] }
  end

  def locks_without_levels
    return [] unless locked.is_a?(Array) && levels.is_a?(Hash)

    (locked - levels.keys).map { |key| [ :locked_section_kinds, "locks #{key} without a difficulty target" ] }
  end

  def keep_hidden(attrs, field, hidden)
    return unless attrs.key?(field)

    known = ExerciseSection.keys
    attrs[field] = hidden.is_a?(Hash) ? hidden.slice(*known).merge(attrs[field]) : attrs[field] | (hidden & known)
  end
end
