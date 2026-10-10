# Display only: must never acquire a relationship to ConceptBucket, which decides where mastery records.
class ConceptGroup
  CORE = "core".freeze

  # A concept in two groups takes the first match, so the lookup stays total if the constants ever overlap.
  NAMED = [
    [ "data_modeling",      AiService::DATA_MODELING_CONCEPTS ],
    [ "domain_modeling",    AiService::DOMAIN_MODELING_CONCEPTS ],
    [ "silent_correctness", AiService::SILENT_CORRECTNESS_CONCEPTS ],
    [ "meta_skill",         AiService::META_SKILL_CONCEPTS ],
    [ "code_smell",         AiService::CODE_SMELL_CONCEPTS ],
    [ "oo_design",          AiService::OO_DESIGN_CONCEPTS ],
    [ "module_design",      AiService::MODULE_DESIGN_CONCEPTS ]
  ].freeze

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
