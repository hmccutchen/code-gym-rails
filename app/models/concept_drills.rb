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
  # a large group outright. One fewer than the slots that can host a drilled
  # concept — every slot but the fourth — so on the fullest day single-concept
  # drills still leave one host for evidence-driven reinforcement or an
  # overdue retention check.
  MAX_CONCURRENT = ExerciseSection.slots.count { |_slot, kinds| kinds.none?(&:fourth?) } - 1

  LimitReached = Class.new(StandardError)

  Entry = Data.define(:bucket, :group, :concepts)

  # Only rows in the user's current slice and its vocabularies: a drill left
  # behind by a language change or a renamed concept neither counts against
  # the cap nor can be reached to stop, so it is simply inert until the slice
  # holds it again.
  def self.for(user)
    scopes = ConceptBucket.slice_for(user.language).map { |bucket| ConceptMastery.in_bucket(bucket) }
    new(user.concept_masteries.drilling.merge(scopes.reduce(:or)).order(:drilled_at, :id).to_a)
  end

  # Returns false when the concept was already drilled and nothing changed. A
  # concept whose group is drilled joins that group, so a member that mastery
  # cleared comes back as a member and not as a second entry for the same gap.
  def self.start!(user, concept:, bucket:)
    raise ArgumentError, "#{concept} is not in #{bucket}" unless ConceptBucket.vocabulary_for(bucket).include?(concept)

    user.with_lock do
      drills = self.for(user)
      next false if drills.drilling?(concept, bucket)

      group = ConceptGroup.for(concept)
      group = nil unless drills.group_drilling?(group, bucket)
      raise LimitReached if group.nil? && drills.full?

      mark!(user, concept, bucket, group: group)
      true
    end
  end

  # Lone drills of the group's own members fold into it, so they are not
  # counted against the cap the group would then replace them under.
  def self.start_group!(user, group:, bucket:)
    concepts = concepts_in(group, bucket)
    raise ArgumentError, "#{bucket} holds nothing from #{group}" if concepts.empty?

    user.with_lock do
      drills = self.for(user)
      raise LimitReached if drills.count_without(bucket, group, concepts) >= MAX_CONCURRENT

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

  # How many drills would remain if this group and lone drills of these
  # concepts were set aside.
  def count_without(bucket, group, concepts)
    entries.count do |entry|
      next false if entry.bucket != bucket
      next false if entry.group == group
      !(entry.group.nil? && concepts.include?(entry.concepts.first))
    end
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
