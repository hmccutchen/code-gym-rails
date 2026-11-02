# Reads vocabularies with no rung, the strictest list, because the plan never reads difficulty targets.
class DayHosts
  def initialize(language, mode:, gotcha: nil)
    @language     = language
    @mode         = mode
    @gotcha       = gotcha
    @vocabularies = {}
  end

  def planning_host?(kind) = kind.planning_host?(mode: @mode)

  def can_tag?(kind, concept, bucket)
    planning_host?(kind) && ConceptBucket.for(kind.key, @language) == bucket && vocabulary(kind).include?(concept)
  end

  def hosts(kinds, concept, bucket)
    kinds.select { |kind| can_tag?(kind, concept, bucket) }
  end

  private

  def vocabulary(kind)
    @vocabularies[kind] ||= ConceptVocabulary.selectable_for_section(kind.key, @language, mode: @mode, gotcha: @gotcha).to_set
  end
end
