# Every kind gets an entry whether or not it is targeted; callers filter for targets themselves.
class LadderCoverage
  Entry = Data.define(:kind, :pairs, :grounded) do
    def gaps = pairs - grounded
  end

  def self.for(user)
    pairs_by_kind = ConceptHosts.for(user, difficulty: KindDifficulty.for(user)).pairs_by_kind
    grounded = laddered_pairs(pairs_by_kind.values.flatten(1).uniq)

    new(pairs_by_kind.to_h { |kind, pairs| [ kind, Entry.new(kind: kind, pairs: pairs, grounded: pairs & grounded) ] })
  end

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
