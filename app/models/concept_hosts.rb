# Which section kinds can host a (concept, bucket): every kind whose
# selectable vocabulary can include it, across every code_review mode, every
# rung, and each of the user's languages. Derived from the same registry
# generation reads, never written down as a table. LadderCoverage reads this
# for difficulty targets and the progress page for reachability.
#
# Every rung by default, since a target can change: the progress page asks
# what could ever be offered. `difficulty`, when given, narrows each targeted
# kind to its own level, which is what generation will actually ask for.
class ConceptHosts
  def self.for(user, difficulty: nil)
    languages = ConceptBucket.language_buckets_for(user.language)
    new(ExerciseSection.all.index_with { |kind| offerable_pairs(kind, languages, rungs_for(kind, difficulty)) })
  end

  def self.rungs_for(kind, difficulty)
    level = difficulty&.level_for(kind)
    level ? [ level ] : KindDifficulty::LEVELS
  end
  private_class_method :rungs_for

  # The mode is handed to every kind and read only by code_review, whose
  # selectable vocabulary is the one that varies by day.
  def self.offerable_pairs(kind, languages, rungs)
    languages.flat_map do |language|
      bucket = ConceptBucket.for(kind.key, language)
      DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys.product(rungs)
        .flat_map { |mode, rung| ProblemSetIngest.selectable_vocabulary_for(kind.key, language, mode: mode, rung: rung) }
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
