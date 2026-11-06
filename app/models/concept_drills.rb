class ConceptDrills
  # Counted in drills, a group as one; stated rather than derived. See docs/decisions/drills.md.
  MAX_CONCURRENT = 2

  LimitReached = Class.new(StandardError)

  Entry = Data.define(:bucket, :group, :concepts, :reserved_concepts)
  Intent = Data.define(:id, :concept, :language, :drilled_at, :drill_group, :reserved)
  Outcome = Data.define(:status, :drills) do
    def value!
      raise LimitReached if status == :full

      status == :started
    end
  end

  def self.for(user)
    scope = user.concept_masteries
    new(scope.drilling.or(scope.reconciling).in_buckets(ConceptBucket.slice_for(user.language)).order(:id).to_a)
  end

  # Returns false when nothing changed. A concept whose group is drilled joins that group.
  def self.start!(user, concept:, bucket:)
    start(user, concept: concept, bucket: bucket).value!
  end

  def self.start(user, concept:, bucket:)
    raise ArgumentError, "#{concept} is not in #{bucket}" unless ConceptBucket.vocabulary_for(bucket).include?(concept)

    user.with_lock do
      PracticePolicyMode.active?(user)
      drills = self.for(user)
      if drills.drilling?(concept, bucket)
        repeat!(user, drills.targets(concept: concept, bucket: bucket))
        next Outcome.new(status: drills.reserved?(concept, bucket) ? :already_reserved : :already, drills: drills)
      end
      next Outcome.new(status: :full, drills: drills) unless drills.can_start?(concept, bucket)

      mark!(user, [ concept ], bucket, group: drills.joinable_group(concept, bucket), end_pause: true)
      Outcome.new(status: :started, drills: drills)
    end
  end

  # Returns false when already drilled: a repeat press must not re-add cleared members or restamp rotation order.
  def self.start_group!(user, group:, bucket:)
    start_group(user, group: group, bucket: bucket).value!
  end

  def self.start_group(user, group:, bucket:)
    concepts = concepts_in(group, bucket)
    raise ArgumentError, "#{bucket} holds nothing from #{group}" if concepts.empty?

    user.with_lock do
      PracticePolicyMode.active?(user)
      drills = self.for(user)
      if drills.group_drilling?(group, bucket)
        repeat!(user, drills.targets(group: group, bucket: bucket))
        next Outcome.new(status: drills.group_reserved?(group, bucket) ? :already_reserved : :already, drills: drills)
      end
      next Outcome.new(status: :full, drills: drills) unless drills.can_start_group?(group, bucket)

      mark!(user, concepts, bucket, group: group, end_pause: false)
      Outcome.new(status: :started, drills: drills)
    end
  end

  # Returns the group that stopped, or nil for a lone drill; a member always stops as its whole group.
  def self.stop!(user, concept:, bucket:)
    user.with_lock do
      PracticePolicyMode.active?(user)
      drills = self.for(user)
      group = drills.group_for(concept, bucket)
      targets = group ? drills.targets(group: group, bucket: bucket) : drills.targets(concept: concept, bucket: bucket)
      clear!(user, targets)
      group
    end
  end

  def self.stop_group!(user, group:, bucket:)
    user.with_lock do
      PracticePolicyMode.active?(user)
      clear!(user, self.for(user).targets(group: group, bucket: bucket))
    end
  end

  def self.concepts_in(group, bucket)
    ConceptGroup.concepts(group) & ConceptBucket.vocabulary_for(bucket)
  end

  def self.mark!(user, concepts, bucket, group:, end_pause:)
    rows = user.concept_masteries.where(concept: concepts, language: bucket).order(:id).lock.to_a
    existing = rows.map(&:concept)
    rows += (concepts - existing).map { |concept| user.concept_masteries.new(concept: concept, language: bucket) }
    operation = { "type" => "drill", "action" => "set", "drilled_at" => Time.current.utc.iso8601(6),
      "drill_group" => group, "end_pause" => end_pause }
    rows.each do |row|
      row.apply_mastery_operation(operation)
      row.save!
    end
  end
  private_class_method :mark!

  def self.clear!(user, targets)
    user.concept_masteries.where(id: targets.map(&:id)).order(:id).lock.each do |row|
      row.apply_mastery_operation("type" => "drill", "action" => "clear")
      row.save!
    end
  end
  private_class_method :clear!

  def self.repeat!(user, targets)
    user.concept_masteries.where(id: targets.reject(&:reserved).map(&:id)).reconciling.order(:id).lock.each do |row|
      row.apply_mastery_operation("type" => "drill", "action" => "set", "drilled_at" => row.drilled_at.utc.iso8601(6),
        "drill_group" => row.drill_group, "end_pause" => false)
      row.save!
    end
    false
  end
  private_class_method :repeat!

  attr_reader :entries

  def initialize(rows)
    @rows = rows.filter_map { |row| accepted_intent(row) }.sort_by { |row| [ row.drilled_at, row.id ] }
    @entries = build_entries(@rows)
  end

  def count = entries.size
  def full? = count >= MAX_CONCURRENT
  def any?  = entries.any?
  def reservations? = @rows.any?(&:reserved)

  def reserved?(concept, bucket)
    @rows.any? { |row| row.concept == concept && row.language == bucket && row.reserved }
  end

  def group_reserved?(group, bucket)
    targets(group: group, bucket: bucket).any?(&:reserved)
  end

  def targets(bucket:, concept: nil, group: nil)
    @rows.select { |row| row.language == bucket && (group ? row.drill_group == group : row.concept == concept) }
  end

  def drilling?(concept, bucket)
    @rows.any? { |cm| cm.concept == concept && cm.language == bucket }
  end

  def can_start?(concept, bucket)
    return false if drilling?(concept, bucket)

    !full? || joinable_group(concept, bucket).present?
  end

  def can_start_group?(group, bucket)
    return false if group_drilling?(group, bucket)

    members  = ConceptDrills.concepts_in(group, bucket)
    absorbed = entries.count { |entry| entry.bucket == bucket && entry.group.nil? && members.include?(entry.concepts.first) }
    count - absorbed < MAX_CONCURRENT
  end

  def joinable_group(concept, bucket)
    group = ConceptGroup.for(concept)
    group if group_drilling?(group, bucket)
  end

  def group_for(concept, bucket)
    @rows.find { |cm| cm.concept == concept && cm.language == bucket }&.drill_group
  end

  def group_drilling?(group, bucket)
    @rows.any? { |cm| cm.drill_group == group && cm.language == bucket }
  end

  private

  def accepted_intent(row)
    restorable = ConceptMastery::Reconciliation.restorable_drill(journal: row.review_reconciliation)
    return unless row.drilled_at || restorable

    Intent.new(id: row.id, concept: row.concept, language: row.language,
      drilled_at: row.drilled_at || Time.iso8601(restorable.fetch("drilled_at")),
      drill_group: row.drilled_at ? row.drill_group : restorable.fetch("drill_group"),
      reserved: row.drilled_at.nil?)
  end

  def build_entries(rows)
    rows.group_by { |cm| [ cm.language, cm.drill_group, cm.drill_group ? nil : cm.concept ] }
      .map do |(bucket, group, _), members|
        Entry.new(bucket: bucket, group: group, concepts: members.map(&:concept),
          reserved_concepts: members.select(&:reserved).map(&:concept))
      end
  end
end
