# Each kind is read at its rung, its target or else the skill level, since the prompt grounds every kind at it.
class LadderCoverage
  Entry = Data.define(:kind, :pairs, :grounded) do
    def gaps = pairs - grounded
  end

  def self.for(user)
    at_rungs = KindDifficulty.new(levels: user.kind_rungs, locked: [])
    pairs_by_kind = ConceptHosts.for(user, difficulty: at_rungs).pairs_by_kind
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
