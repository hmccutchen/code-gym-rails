# Each kind is read at its rung, since the prompt grounds every kind at it; gaps skip kinds the plan can never pick.
class LadderCoverage
  Entry = Data.define(:kind, :pairs, :grounded) do
    def gaps = pairs - grounded
  end

  def self.for(user)
    at_rungs = KindDifficulty.new(levels: user.kind_rungs, locked: [])
    pairs_by_kind = ConceptHosts.for(user, difficulty: at_rungs).pairs_by_kind
    grounded = laddered_pairs(pairs_by_kind.values.flatten(1).uniq)

    preferences = KindPreferences.for(user)
    new(pairs_by_kind.to_h { |kind, pairs| [ kind, Entry.new(kind: kind, pairs: pairs, grounded: pairs & grounded) ] },
        offered: ExerciseSection.all.reject { |kind| preferences.excluded?(kind) })
  end

  def self.laddered_pairs(pairs)
    ConceptReference.where(concept: pairs.map(&:first).uniq, language: pairs.map(&:last).uniq)
                    .select(&:ladder?)
                    .map { |reference| [ reference.concept, reference.language ] }
  end
  private_class_method :laddered_pairs

  def initialize(entries, offered:)
    @entries = entries
    @offered = offered
  end

  def for_kind(kind)
    @entries.fetch(kind)
  end

  def gaps
    @offered.flat_map { |kind| for_kind(kind).gaps }.uniq
  end

  def grounding_kinds(concept, bucket)
    @offered.select { |kind| for_kind(kind).pairs.include?([ concept, bucket ]) }
  end
end
