# The short lesson a Learn page shows for a concept: a definition, an everyday
# comparison and where it stops, the common mix-up, where you meet it, habits
# each with their catch, a question to carry and a quick test. Every section
# is optional, since not every concept has a fitting comparison.
#
# The one authority for the lesson's shape. AiService asks for these keys,
# .from_provider holds a reply to them at the boundary, and learn/show
# renders them in this order. Pure.
module ConceptLesson
  TEXT_SECTIONS = %w[definition comparison comparison_limit misunderstanding carry_question quick_test].freeze
  SECTIONS = %w[definition comparison comparison_limit misunderstanding situations habits carry_question quick_test].freeze

  WORD_TARGET = 350
  MAX_TEXT_LENGTH = 600
  MAX_SITUATIONS = 4
  MAX_HABITS = 4

  # The lesson as stored, or nil when the reply held nothing usable. An unusable
  # section is dropped rather than failing the write-up, since the lesson is
  # outside the reference's required fields, the way the guide and ladder are.
  def self.from_provider(value)
    return unless value.is_a?(Hash)

    lesson = TEXT_SECTIONS.index_with { |key| usable_text(value[key]) }
    lesson["situations"] = usable_list(value["situations"], MAX_SITUATIONS) { |entry| usable_text(entry) }
    lesson["habits"] = usable_list(value["habits"], MAX_HABITS) { |entry| usable_habit(entry) }
    lesson.compact_blank.presence
  end

  def self.usable_text(value)
    text = value.is_a?(String) ? value.strip : nil
    text if text.present? && text.length <= MAX_TEXT_LENGTH
  end

  def self.usable_list(value, limit)
    return [] unless value.is_a?(Array)

    value.filter_map { |entry| yield entry }.first(limit)
  end

  # A habit is shown with its catch directly after it, so one without a catch
  # is dropped rather than shown half.
  def self.usable_habit(entry)
    return unless entry.is_a?(Hash)

    habit, catch = usable_text(entry["habit"]), usable_text(entry["catch"])
    { "habit" => habit, "catch" => catch } if habit && catch
  end
  private_class_method :usable_text, :usable_list, :usable_habit
end
