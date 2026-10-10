class ConceptDrills
  # Counted in drills, a group as one; stated rather than derived. See CLAUDE.md, "Drills".
  MAX_CONCURRENT = 2

  LimitReached = Class.new(StandardError)

  Entry = Data.define(:bucket, :group, :concepts)

  def self.for(user)
    new(user.concept_masteries.drilling.in_buckets(ConceptBucket.slice_for(user.language)).order(:drilled_at, :id).to_a)
  end

  # Returns false when nothing changed. A concept whose group is drilled joins that group.
  def self.start!(user, concept:, bucket:)
    raise ArgumentError, "#{concept} is not in #{bucket}" unless ConceptBucket.vocabulary_for(bucket).include?(concept)

    user.with_lock do
      drills = self.for(user)
      next false if drills.drilling?(concept, bucket)
      raise LimitReached unless drills.can_start?(concept, bucket)

      mark!(user, concept, bucket, group: drills.joinable_group(concept, bucket), end_pause: true)
      true
    end
  end

  # Returns false when already drilled: a repeat press must not re-add cleared members or restamp rotation order.
  def self.start_group!(user, group:, bucket:)
    concepts = concepts_in(group, bucket)
    raise ArgumentError, "#{bucket} holds nothing from #{group}" if concepts.empty?

    user.with_lock do
      drills = self.for(user)
      next false if drills.group_drilling?(group, bucket)
      raise LimitReached unless drills.can_start_group?(group, bucket)

      concepts.each { |concept| mark!(user, concept, bucket, group: group, end_pause: false) }
      true
    end
  end

  # Returns the group that stopped, or nil for a lone drill; a member always stops as its whole group.
  def self.stop!(user, concept:, bucket:)
    cm = user.concept_masteries.drilling.find_by(concept: concept, language: bucket)
    return nil if cm.nil?
    return cm.clear_drill! && nil if cm.drill_group.nil?

    stop_group!(user, group: cm.drill_group, bucket: bucket)
    cm.drill_group
  end

  def self.stop_group!(user, group:, bucket:)
    user.concept_masteries.drilling.where(drill_group: group, language: bucket).each(&:clear_drill!)
  end

  def self.concepts_in(group, bucket)
    ConceptGroup.concepts(group) & ConceptBucket.vocabulary_for(bucket)
  end

  def self.mark!(user, concept, bucket, group:, end_pause:)
    cm = user.concept_masteries.find_or_initialize_by(concept: concept, language: bucket)
    cm.end_pause if end_pause && cm.tier_paused?
    cm.update!(drilled_at: Time.current, drill_group: group)
  end
  private_class_method :mark!

  attr_reader :entries

  def initialize(rows)
    @rows    = rows
    @entries = build_entries(rows)
  end

  def count = entries.size
  def full? = count >= MAX_CONCURRENT
  def any?  = entries.any?

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

  def build_entries(rows)
    rows.group_by { |cm| [ cm.language, cm.drill_group, cm.drill_group ? nil : cm.concept ] }
        .map { |(bucket, group, _), members| Entry.new(bucket: bucket, group: group, concepts: members.map(&:concept)) }
  end
end
