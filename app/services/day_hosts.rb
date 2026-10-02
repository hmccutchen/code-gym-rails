# Which kinds can tag a concept on one day: the kind must record the concept
# under the concept's own bucket, and the generation prompt must be allowed to
# offer it there. Read with no rung, the strictest list, because the plan
# never reads difficulty targets. Pure; DailyPlan and CoverageException both
# ask it.
class DayHosts
  def initialize(language, mode:)
    @language     = language
    @mode         = mode
    @vocabularies = {}
  end

  def can_tag?(kind, concept, bucket)
    ConceptBucket.for(kind.key, @language) == bucket && vocabulary(kind).include?(concept)
  end

  def hosts(kinds, concept, bucket)
    kinds.select { |kind| can_tag?(kind, concept, bucket) }
  end

  private

  def vocabulary(kind)
    @vocabularies[kind] ||= ProblemSetIngest.selectable_vocabulary_for(kind.key, @language, mode: @mode).to_set
  end
end
