# Which section kinds can host a (concept, bucket): every kind whose
# selectable vocabulary can include it, across every code_review mode and
# each of the user's languages. Derived from the same registry generation
# reads, never written down as a table. LadderCoverage reads this for
# difficulty targets and the progress page for reachability.
class ConceptHosts
  def self.for(user)
    languages = ConceptBucket.language_buckets_for(user.language)
    new(ExerciseSection.all.index_with { |kind| offerable_pairs(kind, languages) })
  end

  # The mode is handed to every kind and read only by code_review, whose
  # selectable vocabulary is the one that varies by day.
  def self.offerable_pairs(kind, languages)
    languages.flat_map do |language|
      bucket = ConceptBucket.for(kind.key, language)
      DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys
        .flat_map { |mode| ProblemSetIngest.selectable_vocabulary_for(kind.key, language, mode: mode) }
        .map { |concept| [ concept, bucket ] }
    end.uniq
  end
  private_class_method :offerable_pairs

  attr_reader :pairs_by_kind

  def initialize(pairs_by_kind)
    @pairs_by_kind = pairs_by_kind
  end

  def kinds_for(concept, bucket)
    pairs_by_kind.select { |_kind, pairs| pairs.include?([ concept, bucket ]) }.keys
  end
end
