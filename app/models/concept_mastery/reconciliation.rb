class ConceptMastery::Reconciliation
  Result = Data.define(:state, :journal)
  OPERATION_FIELDS = {
    "review" => %w[type response_id work_on reviewed_on occurred_at sections pending_sections],
    "session" => %w[type response_id],
    "skip" => %w[type response_id work_on reviewed_on],
    "set" => %w[type action drilled_at drill_group end_pause],
    "clear" => %w[type action]
  }.freeze

  def self.snapshot(record)
    record.attributes.slice(*ConceptMastery::Transition::FIELDS).transform_values do |value|
      case value
      when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
      when Date then value.iso8601
      else value
      end
    end
  end

  def self.apply(current:, journal:, operation:)
    validate_operation!(operation)
    decoded = decode(journal)
    return Result.new(state: ConceptMastery::Transition.apply(current, operation), journal: {}) if decoded == {} && !pending?(operation)

    baseline = decoded == {} ? current.deep_dup : decoded.fetch("baseline")
    validate_state!(baseline)
    operations = decoded == {} ? [] : decoded.fetch("operations")
    replace_or_append(operations, operation)
    compact(baseline, operations)
  end

  def self.restorable_drill(journal:)
    decoded = decode(journal)
    return if decoded == {}

    intent = decoded.fetch("baseline").slice("drilled_at", "drill_group")
    decoded.fetch("operations").each do |operation|
      next unless operation.fetch("type") == "drill"

      intent = operation.fetch("action") == "clear" ? {} : operation.slice("drilled_at", "drill_group")
    end
    intent if intent["drilled_at"]
  end

  def self.decode(value)
    return {} if value == {}

    exact_keys!(value, %w[version baseline operations])
    invalid! unless value["version"] == 1
    validate_state!(value["baseline"])
    operations = value["operations"]
    invalid! unless operations.is_a?(Array) && operations.any?
    operations.each { |operation| validate_operation!(operation) }
    invalid! unless pending?(operations.first)
    review_ids = operations.select { |operation| operation["type"] == "review" }.map { |operation| operation["response_id"] }
    invalid! unless review_ids.uniq == review_ids
    value.deep_dup
  end

  def self.replace_or_append(operations, operation)
    index = if operation["type"] == "review"
      operations.index { |entry| entry["type"] == "review" && entry["response_id"] == operation["response_id"] }
    end
    if index
      operations[index] = operations.fetch(index).merge(operation.slice("sections", "pending_sections"))
    else
      operations << operation.deep_dup
    end
  end
  private_class_method :replace_or_append

  def self.compact(baseline, operations)
    boundary = operations.index { |operation| pending?(operation) }
    state = baseline
    retained_baseline = baseline
    operations.each_with_index do |operation, index|
      retained_baseline = state if index == boundary
      state = ConceptMastery::Transition.apply(state, operation)
    end
    journal = boundary ? { "version" => 1, "baseline" => retained_baseline, "operations" => operations.drop(boundary) } : {}
    Result.new(state: state, journal: journal)
  end
  private_class_method :compact

  def self.pending?(operation) = operation["type"] == "review" && operation.fetch("pending_sections").any?
  private_class_method :pending?

  def self.validate_operation!(value)
    invalid! unless value.is_a?(Hash)
    kind = value["type"] == "drill" ? value["action"] : value["type"]
    fields = OPERATION_FIELDS[kind]
    invalid! unless fields
    exact_keys!(value, fields)
    invalid! if fields.include?("response_id") && !(value["response_id"].is_a?(Integer) && value["response_id"].positive?)
    %w[work_on reviewed_on].each { |field| date!(value[field]) if fields.include?(field) }
    timestamp!(value["occurred_at"]) if fields.include?("occurred_at")
    validate_evidence!(value) if kind == "review"
    validate_drill!(value) if kind == "set"
  end
  private_class_method :validate_operation!

  def self.validate_evidence!(value)
    sections = value["sections"]
    invalid! unless sections.is_a?(Hash) && sections.any?
    section_keys!(sections.keys)
    section_keys!(value["pending_sections"])
    invalid! if (sections.keys & value["pending_sections"]).any?
    sections.each_value do |evidence|
      exact_keys!(evidence, %w[rating self_rating])
      invalid! unless ConceptMastery::AI_RATING_RANK.key?(evidence["rating"])
      invalid! unless evidence["self_rating"].nil? || DailyResponse::SELF_RATINGS.include?(evidence["self_rating"])
    end
  end
  private_class_method :validate_evidence!

  def self.validate_drill!(value)
    timestamp!(value["drilled_at"])
    invalid! unless value["drill_group"].nil? || value["drill_group"].is_a?(String)
    invalid! unless [ true, false ].include?(value["end_pause"])
  end
  private_class_method :validate_drill!

  def self.validate_state!(value)
    exact_keys!(value, ConceptMastery::Transition::FIELDS)
    invalid! unless ConceptMastery.tiers.key?(value["tier"])
    %w[streak cooldown_remaining].each { |field| invalid! unless value[field].is_a?(Integer) && value[field] >= 0 }
    invalid! unless value["last_rating"].nil? || ConceptMastery::AI_RATING_RANK.key?(value["last_rating"])
    interval = value["retention_interval_days"]
    invalid! unless interval.nil? || (interval.is_a?(Integer) && interval.positive?)
    date!(value["next_retention_check_on"]) unless value["next_retention_check_on"].nil?
    %w[mastered_at drilled_at].each { |field| timestamp!(value[field]) unless value[field].nil? }
    invalid! unless value["drill_group"].nil? || value["drill_group"].is_a?(String)
  end
  private_class_method :validate_state!

  def self.exact_keys!(value, fields)
    invalid! unless value.is_a?(Hash) && value.keys.sort == fields.sort
  end
  private_class_method :exact_keys!

  def self.section_keys!(value)
    invalid! unless value.is_a?(Array) && value.uniq == value && value.all? { |key| ExerciseSection.keys.include?(key) }
  end
  private_class_method :section_keys!

  def self.date!(value)
    invalid! unless value.is_a?(String) && Date.iso8601(value).iso8601 == value
  rescue Date::Error
    invalid!
  end
  private_class_method :date!

  def self.timestamp!(value)
    invalid! unless value.is_a?(String) && Time.iso8601(value).utc.iso8601(6) == value
  rescue ArgumentError
    invalid!
  end
  private_class_method :timestamp!

  def self.invalid! = raise ArgumentError, "Invalid mastery reconciliation format"
  private_class_method :invalid!
end
