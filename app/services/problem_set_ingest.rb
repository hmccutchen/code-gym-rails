class ProblemSetIngest
  SERVER_STAMPS = %w[pitched_at eased source anchored].freeze

  Suggestion = Data.define(:bucket, :name)

  Unusable = Data.define(:key, :concept, :reason)

  Result = Data.define(:problem_set, :suggested_concepts, :unusable_sections)

  def self.call(problem_set, language:, expected_keys:, code_review_source: nil, pitched_at: nil, eased_for: {}, fixed_concepts: {})
    new(problem_set, language: language, expected_keys: expected_keys, code_review_source: code_review_source,
        pitched_at: pitched_at, eased_for: eased_for, fixed_concepts: fixed_concepts).call
  end

  def self.prune_to_expected_keys(problem_set, expected_keys:)
    problem_set.deep_dup.slice(*expected_keys)
  end

  # Never narrowed: a concept the provider tagged is history, and rewriting it to "other" would destroy the record.
  def self.vocabulary_for(section_key, language)
    case ExerciseSection.find(section_key)&.vocabulary_key
    when :architecture      then AiService::ARCHITECTURE_CONCEPTS
    when :security_concepts then language_config(language)[:security_concepts]
    when :plan_review       then AiService::PLAN_REVIEW_CONCEPTS
    when :ambiguity_hunt    then AiService::AMBIGUITY_HUNT_CONCEPTS
    when :pseudocode_to_code then AiService::PSEUDOCODE_TO_CODE_CONCEPTS
    else                         language_config(language)[:concepts]
    end
  end

  def self.selectable_vocabulary_for(section_key, language, mode: nil, rung: nil)
    vocabulary =
      if mode && section_key == ExerciseSection::CodeReview.key
        code_review_vocabulary(language, mode)
      else
        vocabulary_for(section_key, language)
      end

    excluded = excluded_concepts_for(section_key)
    remaining = excluded.empty? ? vocabulary : vocabulary - excluded
    ExerciseSection.for(section_key).narrow_vocabulary(remaining, rung: rung) & remaining
  end

  def self.code_review_vocabulary(language, mode)
    full = language_config(language)[:concepts]
    mode == :schema_review ? AiService::DATA_MODELING_CONCEPTS : full - AiService::DATA_MODELING_CONCEPTS
  end
  private_class_method :code_review_vocabulary

  def self.excluded_concepts_for(section_key)
    ExerciseSection.for(section_key).excluded_vocabulary_keys.flat_map do |key|
      case key
      when :data_modeling then AiService::DATA_MODELING_CONCEPTS
      when :domain_modeling then AiService::DOMAIN_MODELING_CONCEPTS
      when :meta_skill    then AiService::META_SKILL_CONCEPTS
      when :code_smell    then AiService::CODE_SMELL_CONCEPTS
      when :oo_design     then AiService::OO_DESIGN_CONCEPTS
      when :module_design then AiService::MODULE_DESIGN_CONCEPTS
      when :silent_correctness then AiService::SILENT_CORRECTNESS_CONCEPTS
      else                     []
      end
    end
  end
  private_class_method :excluded_concepts_for

  def self.language_config(language)
    AiService::LANGUAGE_CONFIG.fetch(language) do
      raise AiService::Error, "Unsupported generation language: #{language.inspect}"
    end
  end
  private_class_method :language_config

  def initialize(problem_set, language:, expected_keys:, code_review_source: nil, pitched_at: nil, eased_for: {}, fixed_concepts: {})
    @problem_set        = problem_set
    @language           = language
    @expected_keys      = expected_keys
    @code_review_source = code_review_source
    @pitched_at         = pitched_at
    @eased_for          = eased_for
    @fixed_concepts     = fixed_concepts
    @suggested_concepts = []
    @unusable_sections  = []
  end

  def call
    reject_missing_sections!
    warn_unrequested_sections!
    prune_retry_extras!
    prune_unplanned_slots!
    format_code!
    reject_unusable_sections!
    enforce_fixed_concepts!
    normalize_concepts!
    normalize_answer_scaffolds!
    normalize_diagrams!
    arrange_sections!
    strip_current_schemas!
    strip_server_stamps!
    ground_code_review!
    stamp_pitched_rungs!

    Result.new(problem_set: @problem_set, suggested_concepts: @suggested_concepts, unusable_sections: @unusable_sections)
  end

  private

  def format_code!
    fields = @problem_set.flat_map do |key, section|
      next [] unless section.is_a?(Hash)

      ExerciseSection.for(key).code_fields.select { |field| section[field].is_a?(String) && section[field].present? }.map { |field| [ section, field ] }
    end
    formatted = CodeFormat.all(fields.map { |section, field| section[field] }, language: @language)
    fields.zip(formatted).each { |(section, field), code| section[field] = code }
  end

  def reject_missing_sections!
    missing = @expected_keys.reject { |key| ExerciseSection.present?(@problem_set, key) }
    return if missing.empty?

    raise AiService::InvalidResponseError,
          "Provider omitted intended section(s): #{missing.join(', ')}"
  end

  # JSON-serialized because the keys are provider-controlled, and a newline in one would forge a log line.
  def warn_unrequested_sections!
    unrequested = @problem_set.keys - @expected_keys
    return if unrequested.empty?

    Rails.logger.warn(
      "[unrequested_sections] provider returned section(s) the day did not intend: " \
      "#{unrequested.to_json} (intended: #{@expected_keys.to_json})"
    )
  end

  def prune_retry_extras!
    return if @fixed_concepts.empty?

    @problem_set = self.class.prune_to_expected_keys(@problem_set, expected_keys: @expected_keys)
  end

  def prune_unplanned_slots!
    return if resolved_slot_count <= ExerciseSection::MAX_SECTIONS

    ExerciseSection.slots.each_value do |kinds|
      keys = kinds.map(&:key)
      @problem_set = @problem_set.except(*keys) if (keys & @expected_keys).empty?
    end
  end

  def resolved_slot_count
    ExerciseSection.slots.values.count { |kinds| ExerciseSection.resolved_key(@problem_set, kinds) }
  end

  def reject_unusable_sections!
    pending = ExerciseSection.resolved_keys(@problem_set)
    while (key = pending.shift)
      successor = reject_if_unusable(key)
      pending << successor if successor
    end
    return if ExerciseSection.resolved_keys(@problem_set).any?

    raise AiService::InvalidResponseError, "No usable section left: #{@unusable_sections.map(&:reason).join('; ')}"
  end

  def reject_if_unusable(key)
    ExerciseSection.for(key).reject_unusable!(@problem_set[key])
    nil
  rescue AiService::InvalidResponseError => e
    @unusable_sections << Unusable.new(key: key, concept: usable_concept(key), reason: e.message)
    @problem_set = @problem_set.except(key)
    ExerciseSection.resolved_key(@problem_set, slot_kinds_for(key))
  end

  def usable_concept(key)
    concept = @problem_set.dig(key, "concept")
    concept if self.class.vocabulary_for(key, @language).include?(concept)
  end

  def slot_kinds_for(key)
    ExerciseSection.slots.values.find { |kinds| kinds.map(&:key).include?(key) }
  end

  # Before normalize_concepts!, which would pass a mismatched concept through or launder it to "other" silently.
  def enforce_fixed_concepts!
    @fixed_concepts.each do |key, concept|
      actual = @problem_set.dig(key, "concept")
      next if actual == concept

      raise AiService::InvalidResponseError,
            "Retry for #{key} returned concept #{actual.inspect}, not #{concept.inspect}"
    end
  end

  def normalize_concepts!
    @problem_set.each do |section_key, section|
      next unless section.is_a?(Hash) && section.key?("concept")

      original = section["concept"]
      next if self.class.vocabulary_for(section_key, @language).include?(original)

      section["concept"] = "other"
      @suggested_concepts << Suggestion.new(bucket: ConceptBucket.for(section_key, @language), name: original)
    end
  end

  def normalize_answer_scaffolds!
    @problem_set.each do |section_key, section_data|
      kind = ExerciseSection.find(section_key)
      next unless section_data.is_a?(Hash)

      unless kind&.scaffolded?
        section_data.delete("answer_scaffold")
        next
      end

      labels = kind.normalize_scaffold(section_data["answer_scaffold"])
      labels.any? ? section_data["answer_scaffold"] = labels : section_data.delete("answer_scaffold")
    end
  end

  def normalize_diagrams!
    @problem_set.each do |section_key, section_data|
      next unless section_data.is_a?(Hash)

      keep_usable_diagram(section_data, allowed: ExerciseSection.find(section_key)&.diagrammable?)
      reference = section_data["reference"]
      keep_usable_diagram(reference, allowed: true) if reference.is_a?(Hash) && reference.key?("diagram")
    end
  end

  def keep_usable_diagram(holder, allowed:)
    diagram = holder["diagram"]
    allowed && MermaidSource.usable?(diagram) ? holder["diagram"] = diagram.strip : holder.delete("diagram")
  end

  def strip_current_schemas!
    @problem_set.each_value do |section_data|
      section_data.delete("current_schema") if section_data.is_a?(Hash)
    end
  end

  def ground_code_review!
    return if @code_review_source.nil?
    return unless ExerciseSection.present?(@problem_set, "code_review")

    section = @problem_set["code_review"]
    section["scenario"] = @code_review_source.scenario
    section["source"]   = @code_review_source.id

    schema = @code_review_source.current_schema
    section["current_schema"] = schema if schema
  end

  # Every section, since an unrequested one can win its slot; runs before ground_code_review! restamps `source`.
  def strip_server_stamps!
    @problem_set.each_value do |section|
      next unless section.is_a?(Hash)

      SERVER_STAMPS.each { |stamp| section.delete(stamp) }
    end
  end

  # Runs after normalize_concepts!, since `eased` depends on the concept the set will carry.
  def stamp_pitched_rungs!
    return if @pitched_at.nil?

    @problem_set.each do |key, section|
      next unless section.is_a?(Hash) && @pitched_at.key?(key)

      section["pitched_at"] = @pitched_at.fetch(key)
      section["eased"] = true if @eased_for.fetch(key, []).include?(section["concept"])
    end
  end

  def arrange_sections!
    ExerciseSection.resolved_keys(@problem_set).each do |key|
      ExerciseSection.for(key).arrange!(@problem_set[key])
    end
  end
end
