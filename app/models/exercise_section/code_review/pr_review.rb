module ExerciseSection::CodeReview::PrReview
  MODE = :pr_review
  FIELD = "review_variant".freeze
  VALUE = "pr_review_v1".freeze
  REQUIREMENTS = "requirements".freeze
  FILE_RANGE = (2..2).freeze
  MAX_SCENARIO_LENGTH = 400
  MAX_QUESTION_LENGTH = 300
  MAX_REQUIREMENT_LENGTH = 240
  PUBLIC_FIELDS = %w[scenario question concept requirements].freeze

  def self.section?(section) = section.is_a?(Hash) && section[FIELD] == VALUE

  def self.validate!(section, file_parts:)
    file_fields = FILE_RANGE.end.times.flat_map { |index| file_parts.map { |part| "file_#{index + 1}_#{part}" } }
    requirements = section[REQUIREMENTS]
    valid = (section.keys - PUBLIC_FIELDS - file_fields).empty? &&
      short_line?(section["scenario"], MAX_SCENARIO_LENGTH) &&
      short_line?(section["question"], MAX_QUESTION_LENGTH) &&
      (!section.key?("concept") || short_line?(section["concept"], MAX_REQUIREMENT_LENGTH)) &&
      requirements.is_a?(Array) && (1..3).cover?(requirements.size) &&
      requirements.all? { |requirement| short_line?(requirement, MAX_REQUIREMENT_LENGTH) }
    return if valid

    raise ProviderError::InvalidResponseError, "PR Review returned invalid public context or unsupported fields"
  end

  def self.validate_files!(files)
    return if files.all? { |file| file.path.match?(%r{\Aapp/(?:[\w-]+/)+[\w-]+\.rb\z}) && Prism.parse(file.code).success? }

    raise ProviderError::InvalidResponseError, "PR Review requires valid Ruby code in relative application paths"
  end

  def self.short_line?(value, max)
    value.is_a?(String) && value.present? && value.length <= max && !value.match?(/[[:cntrl:]]/)
  end
  private_class_method :short_line?
end
