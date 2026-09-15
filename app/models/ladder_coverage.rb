# Which concepts can ground each section kind's difficulty target, and which of
# them already have a ladder. Every kind gets an entry whether or not it is
# targeted; callers that act only on targets filter for themselves.
class LadderCoverage
  Entry = Data.define(:kind, :pairs, :grounded) do
    def gaps = pairs - grounded
  end

  def self.for(user)
    languages = ConceptBucket.language_buckets_for(user.language)
    pairs_by_kind = ExerciseSection.all.index_with { |kind| offerable_pairs(kind, languages) }
    grounded = laddered_pairs(pairs_by_kind.values.flatten(1).uniq)

    new(pairs_by_kind.to_h { |kind, pairs| [ kind, Entry.new(kind: kind, pairs: pairs, grounded: pairs & grounded) ] })
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

  def self.laddered_pairs(pairs)
    ConceptReference.where(concept: pairs.map(&:first).uniq, language: pairs.map(&:last).uniq)
                    .select(&:ladder?)
                    .map { |reference| [ reference.concept, reference.language ] }
  end
  private_class_method :laddered_pairs

  def initialize(entries)
    @entries = entries
  end

  def for_kind(kind)
    @entries.fetch(kind)
  end

  def gaps_for(kinds)
    kinds.flat_map { |kind| for_kind(kind).gaps }.uniq
  end

  def grounding_kinds(kinds, concept, bucket)
    kinds.select { |kind| for_kind(kind).pairs.include?([ concept, bucket ]) }
  end
end
