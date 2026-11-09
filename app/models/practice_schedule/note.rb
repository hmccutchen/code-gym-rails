class PracticeSchedule::Note
  FIELDS = %w[version policy sequence initial_ready regular_kinds phase selected_kinds assignments continuation].freeze
  REASONS = (ConceptMastery::PracticePolicy::MODES + %w[reinforcement retention drill]).freeze
  ADJUSTMENTS = (%w[normal] + ConceptMastery::PracticePolicy::MODES).freeze

  def self.decode(value)
    return {} if value == {}

    keys!(value, FIELDS + (value.is_a?(Hash) && value.key?("omitted_kind") ? %w[omitted_kind] : []))
    invalid! unless value["version"].eql?(1) && value["policy"].eql?(2)
    integer!(value["sequence"], minimum: 1)
    invalid! unless [ true, false ].include?(value["initial_ready"])
    kinds!(value["regular_kinds"])
    invalid! unless (1..ExerciseSection::MAX_SECTIONS).cover?(value["regular_kinds"].size)
    kinds!(value["selected_kinds"])
    [ value["regular_kinds"], value["selected_kinds"] ].each do |keys|
      invalid! if keys.count { |key| ExerciseSection.for(key).fourth? } > DailyPlan::FOURTH_SLOT_CAPACITY
    end
    invalid! unless (1..ExerciseSection::MAX_SECTIONS).cover?(value["selected_kinds"].size)
    invalid! unless value["phase"].nil? || phase?(value["phase"])
    invalid! if value.key?("omitted_kind") && (!value["regular_kinds"].include?(value["omitted_kind"]) ||
      value["selected_kinds"].include?(value["omitted_kind"]))
    assignments!(value["assignments"], value["selected_kinds"])
    continuation!(value["continuation"], value["sequence"])
    eligible = ExerciseSection.optional_slots(daily: value["regular_kinds"].map { |key| ExerciseSection.for(key) }).values.flatten.map(&:key)
    invalid! unless (value["continuation"]["kind_order"] - eligible).empty?
    value.deep_dup
  end

  def self.assignments!(value, selected)
    invalid! unless value.is_a?(Hash) && (value.keys - selected).empty?
    value.each do |kind, assignment|
      keys!(assignment, %w[concept bucket reason adjustment])
      identity!(assignment)
      invalid! unless ConceptBucket.for(kind, assignment["bucket"]) == assignment["bucket"]
      invalid! unless REASONS.include?(assignment["reason"]) && ADJUSTMENTS.include?(assignment["adjustment"])
    end
  end

  def self.continuation!(value, sequence)
    keys!(value, %w[next_phase kind_order next_kind_index last_omitted_kind service])
    invalid! unless phase?(value["next_phase"])
    kinds!(value["kind_order"])
    integer!(value["next_kind_index"])
    invalid! unless value["kind_order"].empty? ? value["next_kind_index"].zero? : value["next_kind_index"] < value["kind_order"].size
    invalid! unless value["last_omitted_kind"].nil? || ExerciseSection.keys.include?(value["last_omitted_kind"])
    service!(value["service"], sequence)
  end

  def self.service!(value, sequence)
    invalid! unless value.is_a?(Hash)
    kinds!(value.keys)
    value.each_value do |service|
      keys!(service, %w[last_lane last_maintenance concepts])
      invalid! unless [ nil, "practice", "maintenance" ].include?(service["last_lane"])
      invalid! unless [ nil, "retention", "drill" ].include?(service["last_maintenance"])
      invalid! unless service["concepts"].is_a?(Array)
      identities = service["concepts"].map do |entry|
        keys!(entry, %w[concept bucket sequence])
        identity!(entry)
        integer!(entry["sequence"], minimum: 1)
        invalid! if entry["sequence"] > sequence
        entry.values_at("concept", "bucket")
      end
      invalid! unless identities.uniq == identities
    end
  end

  def self.identity!(value)
    invalid! unless ConceptBucket.valid_identity?(concept: value["concept"], bucket: value["bucket"])
  end

  def self.kinds!(value)
    invalid! unless value.is_a?(Array) && value.uniq == value && value.all? { |key| ExerciseSection.keys.include?(key) }
  end

  def self.keys!(value, fields)
    invalid! unless value.is_a?(Hash) && value.keys.sort == fields.sort
  end

  def self.integer!(value, minimum: 0)
    invalid! unless value.is_a?(Integer) && value >= minimum
  end

  def self.phase?(value) = value.is_a?(Integer) && (0...PracticeSchedule::Turns::CYCLE).cover?(value)

  def self.invalid! = raise ArgumentError, "Invalid practice schedule format"
  private_class_method :assignments!, :continuation!, :service!, :identity!, :kinds!, :keys!, :integer!, :phase?, :invalid!
end
