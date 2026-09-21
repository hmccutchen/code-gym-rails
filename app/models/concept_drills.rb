# A user's stated "practise this" bias over concepts, and the one authority for
# how many run at once. It writes only ConceptMastery's two drill columns —
# that model is already the one row per (user, concept, bucket), so a drill on
# a concept the user has never met simply creates the row in its untouched
# state — plus the one tier write drilling is allowed: ending a pause early,
# through the same exit an expired cooldown takes.
#
# Selection reads drills through User#concepts_needing_reinforcement, and a
# drill clears on the same co-favorable rating that marks the concept
# mastered (ConceptMastery.evaluate_concept!). Nothing here decides difficulty.
class ConceptDrills
  # Counted in drills rather than concepts, where a whole group is one: a
  # group is one self-noticed gap, and a cap counted in concepts would refuse
  # a large group outright. Sized so that on the fullest day — every slot but
  # the fourth can host a drilled concept — single-concept drills still leave
  # one host for evidence-driven reinforcement or an overdue retention check.
  MAX_CONCURRENT = ExerciseSection.slot_count - 2

  LimitReached = Class.new(StandardError)

  Entry = Data.define(:bucket, :group, :concepts)

  def self.for(user)
    new(user.concept_masteries.drilling.order(:drilled_at, :id).to_a)
  end

  def self.start!(user, concept:, bucket:)
    raise ArgumentError, "#{concept} is not in #{bucket}" unless ConceptBucket.vocabulary_for(bucket).include?(concept)

    user.with_lock do
      drills = self.for(user)
      next if drills.drilling?(concept, bucket)
      raise LimitReached if drills.full?

      mark!(user, concept, bucket, group: nil)
    end
  end

  def self.start_group!(user, group:, bucket:)
    concepts = concepts_in(group, bucket)
    raise ArgumentError, "#{bucket} holds nothing from #{group}" if concepts.empty?

    user.with_lock do
      drills = self.for(user)
      raise LimitReached if drills.full? && !drills.group_drilling?(group, bucket)

      concepts.each { |concept| mark!(user, concept, bucket, group: group) }
    end
  end

  def self.stop!(user, concept:, bucket:)
    user.concept_masteries.drilling.where(concept: concept, language: bucket).each(&:clear_drill!)
  end

  def self.stop_group!(user, group:, bucket:)
    user.concept_masteries.drilling.where(drill_group: group, language: bucket).each(&:clear_drill!)
  end

  def self.concepts_in(group, bucket)
    ConceptGroup.concepts(group) & ConceptBucket.vocabulary_for(bucket)
  end

  def self.mark!(user, concept, bucket, group:)
    cm = user.concept_masteries.find_or_initialize_by(concept: concept, language: bucket)
    cm.end_pause if cm.tier_paused?
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
