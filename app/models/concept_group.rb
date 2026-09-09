# Which display group a concept renders under on the Learn tab, and the order
# the groups appear in. Display only: this has nothing to do with
# ConceptBucket, which decides where a concept's mastery history records, and
# must never acquire a relationship to it.
#
# Membership is derived from the vocabulary constants rather than restated, so
# a concept that moves between named groups moves in exactly one place.
class ConceptGroup
  CORE = "core".freeze

  # Ordered as a reader meets them: the base vocabulary first, then the named
  # groups from most concrete to most evaluative. A concept in two groups takes
  # the first match — impossible with today's disjoint constants, but the
  # lookup stays total rather than depending on that staying true.
  NAMED = [
    [ "data_modeling",      AiService::DATA_MODELING_CONCEPTS ],
    [ "silent_correctness", AiService::SILENT_CORRECTNESS_CONCEPTS ],
    [ "meta_skill",         AiService::META_SKILL_CONCEPTS ],
    [ "code_smell",         AiService::CODE_SMELL_CONCEPTS ],
    [ "oo_design",          AiService::OO_DESIGN_CONCEPTS ],
    [ "module_design",      AiService::MODULE_DESIGN_CONCEPTS ]
  ].freeze

  ORDER = ([ CORE ] + NAMED.map(&:first)).freeze

  def self.for(concept)
    match = NAMED.find { |_key, concepts| concepts.include?(concept) }
    match ? match.first : CORE
  end

  # A bucket's concepts grouped for display. Empty groups are dropped, which is
  # what makes the four language-independent buckets render as a single flat
  # list without a special case: every one of their concepts falls in CORE.
  def self.grouped(concepts)
    concepts.group_by { |concept| self.for(concept) }
            .sort_by { |key, _concepts| ORDER.index(key) }
  end
end
