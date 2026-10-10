# Derived from the registry generation reads; every rung unless `difficulty` narrows a targeted kind to its level.
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

  # Only code_review reads the mode; its selectable vocabulary is the one that varies by day.
  def self.offerable_pairs(kind, languages, rungs)
    languages.flat_map do |language|
      bucket = ConceptBucket.for(kind.key, language)
      DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys.product(rungs)
        .flat_map { |mode, rung| ConceptVocabulary.selectable_for_section(kind.key, language, mode: mode, rung: rung) }
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
