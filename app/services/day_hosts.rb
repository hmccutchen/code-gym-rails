# Reads vocabularies with no rung, the strictest list, because the plan never reads difficulty targets.
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
