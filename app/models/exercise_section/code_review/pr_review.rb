module ExerciseSection::CodeReview::PrReview
  MODE = :pr_review
  FIELD = "review_variant".freeze
  VALUE = "pr_review".freeze
  REQUIREMENTS = "requirements".freeze
  FIELDS = [ FIELD, REQUIREMENTS ].freeze
  FILE_RANGE = (2..2).freeze
  MAX_SCENARIO_LENGTH = 400
  MAX_QUESTION_LENGTH = 300
  MAX_REQUIREMENT_LENGTH = 240
  MAX_REASON_LENGTH = 400
  MAX_QUOTE_LENGTH = 240
  MAX_OUTCOME_LENGTH = 80
  CASES = %w[acceptable flawed].freeze
  SELECTION_WEIGHTS = CASES.index_with { 0.20 }.merge("ordinary" => 0.60).freeze
  INPUT_FIELDS = [ "scenario", "question", "concept", REQUIREMENTS, PlantedKey::FIELD ].freeze
  KEY_FIELDS = %w[case evidence reason behavior].freeze
  BEHAVIOR_FIELDS = %w[requirement expected observed].freeze
  BEHAVIOR_GUIDANCE = "Record the one-based requirement number and the expected and observed results for its condition. " \
                      "Use short values in the same form, such as Ruby literals when the excerpts show them. " \
                      "For an acceptable change use requirement 1 and matching results. For a blocker use the violated requirement and different results.".freeze

  def self.section?(section) = section.is_a?(Hash) && section[FIELD] == VALUE

  def self.valid_scope?(language:, rung:, file_range:, source:, target:)
    eligible_context?(language: language, rung: rung, source: source) && file_range == FILE_RANGE && CASES.include?(target)
  end

  def self.select_target(mode:, language:, rung:, source:)
    return unless mode == :application_code && eligible_context?(language: language, rung: rung, source: source)

    target = WeightedRoll.pick(SELECTION_WEIGHTS)
    target if CASES.include?(target)
  end

  def self.eligible_context?(language:, rung:, source:)
    language == "ruby_rails" && rung == "mid_level" && source.nil?
  end

  private_class_method :eligible_context?

  def self.valid_context?(section, file_parts:)
    file_fields = FILE_RANGE.end.times.flat_map { |index| file_parts.map { |part| "file_#{index + 1}_#{part}" } }
    (section.keys - INPUT_FIELDS - file_fields).empty? &&
      short_line?(section["scenario"], MAX_SCENARIO_LENGTH) &&
      short_line?(section["question"], MAX_QUESTION_LENGTH) &&
      (!section.key?("concept") || short_line?(section["concept"], MAX_REQUIREMENT_LENGTH)) &&
      public_requirements(section).any?
  end

  def self.public_requirements(section)
    requirements = section[REQUIREMENTS]
    return [] unless requirements.is_a?(Array) && (1..3).cover?(requirements.size)
    return [] unless requirements.all? { |requirement| short_line?(requirement, MAX_REQUIREMENT_LENGTH) }

    requirements
  end

  def self.valid_files?(files)
    files.all? { |file| file.path.match?(%r{\Aapp/(?:[\w-]+/)+[\w-]+\.rb\z}) && Prism.parse(file.code).success? }
  end

  def self.short_line?(value, max)
    value.is_a?(String) && value.present? && value.length <= max && !value.match?(/[[:cntrl:]]/)
  end

  def self.valid_key?(section, target:)
    key = section[PlantedKey::FIELD]
    key.is_a?(Hash) && key.size == KEY_FIELDS.size && KEY_FIELDS.all? { |field| key.key?(field) } && CASES.include?(target) &&
      key["case"] == target && short_line?(key["reason"], MAX_REASON_LENGTH) &&
      evidence_locations(key["evidence"], section: section).present? &&
      behavior_signature(key["behavior"], section: section, review_case: target).present?
  end

  def self.behavior_signature(behavior, section:, review_case:)
    return unless behavior.is_a?(Hash) && behavior.size == BEHAVIOR_FIELDS.size && BEHAVIOR_FIELDS.all? { |field| behavior.key?(field) }

    number, expected, observed = behavior.values_at(*BEHAVIOR_FIELDS)
    requirements = section[REQUIREMENTS]
    return unless requirements.is_a?(Array) && number.is_a?(Integer) && (1..requirements.size).cover?(number)
    return unless short_line?(expected, MAX_OUTCOME_LENGTH) && short_line?(observed, MAX_OUTCOME_LENGTH)

    expected, observed = expected.strip, observed.strip
    matches = case review_case
    when "acceptable" then number == 1 && expected == observed
    when "flawed" then expected != observed
    end
    [ number, expected, observed ] if matches
  end

  def self.evidence_locations(evidence, section:)
    return unless evidence.is_a?(Array) && (1..2).cover?(evidence.size)

    files = ExerciseSection::CodeReview.files(section).index_by(&:path)
    locations = evidence.filter_map { |entry| evidence_location(entry, files) }
    locations if locations.size == evidence.size && locations.uniq.size == locations.size
  end

  def self.evidence_location(entry, files)
    return unless entry.is_a?(Hash) && entry.size == 2 && entry.key?("path") && entry.key?("quote")
    return unless short_line?(entry["quote"], MAX_QUOTE_LENGTH)

    file = files[entry["path"]]
    return unless file

    quote = entry["quote"].strip
    lines = file.code.lines
    matches = lines.each_index.select { |index| lines[index].strip == quote }
    [ file.path, matches.sole + 1 ] if matches.one?
  end
  private_class_method :evidence_location
end
