# The one authority for the lesson's shape: AiService asks for these keys and learn/show renders them in order.
module ConceptLesson
  SECTIONS = %w[definition comparison comparison_limit misunderstanding situations habits carry_question quick_test].freeze

  # The shape the prompt asks for. Every key not listed here is a string.
  LIST_SHAPES = {
    "situations" => [ "string" ],
    "habits" => [ { "habit" => "string", "catch" => "string" } ]
  }.freeze
  TEXT_SECTIONS = (SECTIONS - LIST_SHAPES.keys).freeze

  # Shown together or not at all, so a reader never meets an analogy without where it breaks.
  PAIRED_SECTIONS = %w[comparison comparison_limit].freeze

  WORD_TARGET = 350
  MAX_TEXT_LENGTH = 600
  MAX_SITUATIONS = 4
  MAX_HABITS = 4

  # Drops an unusable section rather than failing, since the lesson is outside the required fields.
  def self.from_provider(value)
    return unless value.is_a?(Hash)

    lesson = TEXT_SECTIONS.index_with { |key| usable_text(value[key]) }
    lesson["situations"] = usable_list(value["situations"], MAX_SITUATIONS) { |entry| usable_text(entry) }
    lesson["habits"] = usable_list(value["habits"], MAX_HABITS) { |entry| usable_habit(entry) }
    lesson.except!(*PAIRED_SECTIONS) unless PAIRED_SECTIONS.all? { |key| lesson[key] }
    lesson.compact_blank.presence
  end

  def self.schema
    SECTIONS.index_with { |key| LIST_SHAPES.fetch(key, "string") }
  end

  def self.usable_text(value)
    text = value.is_a?(String) ? value.strip : nil
    text if text.present? && text.length <= MAX_TEXT_LENGTH
  end

  def self.usable_list(value, limit)
    return [] unless value.is_a?(Array)

    value.filter_map { |entry| yield entry }.first(limit)
  end

  # A habit without its catch is dropped rather than shown half.
  def self.usable_habit(entry)
    return unless entry.is_a?(Hash)

    habit, catch = usable_text(entry["habit"]), usable_text(entry["catch"])
    { "habit" => habit, "catch" => catch } if habit && catch
  end
  private_class_method :usable_text, :usable_list, :usable_habit
end
