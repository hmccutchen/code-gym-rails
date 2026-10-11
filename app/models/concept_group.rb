# Display only: must never acquire a relationship to ConceptBucket, which decides where mastery records.
class ConceptGroup
  CORE = "core".freeze

  NAMED = ConceptVocabulary::GROUPS.map { |key, concepts| [ key.to_s, concepts ] }.freeze

  ORDER = ([ CORE ] + NAMED.map(&:first)).freeze

  def self.concepts(group)
    NAMED.to_h.fetch(group, [])
  end

  def self.for(concept)
    match = NAMED.find { |_key, concepts| concepts.include?(concept) }
    match ? match.first : CORE
  end

  # Dropping empty groups is what renders the language-independent buckets as one flat list.
  def self.grouped(concepts)
    concepts.group_by { |concept| self.for(concept) }
            .sort_by { |key, _concepts| ORDER.index(key) }
  end
end
