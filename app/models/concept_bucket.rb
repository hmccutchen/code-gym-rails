# The vocabulary bucket a concept's history is recorded under. Architecture,
# plan_review, and ambiguity_hunt concepts are each language-independent —
# they transcend any one stack, so they're tracked in their own bucket rather
# than under the day's generation language; every other section buckets
# under that language. Each of the three special buckets is entirely
# disjoint vocabulary (see AiService::ARCHITECTURE_CONCEPTS/
# PLAN_REVIEW_CONCEPTS/AMBIGUITY_HUNT_CONCEPTS), so each gets its own bucket
# rather than being merged into one shared "meta-skills" bucket — the same
# granularity ConceptMastery already uses everywhere else.
#
# Accepts one section or several: a concept tagged on multiple sections the
# same day belongs to a special bucket if any of them is that special
# section (see ConceptMastery.record_review!). Only one special section can
# ever appear in a given day's `sections` list in practice (a section only
# occupies one slot), but the lookup is written to tolerate more than one
# without preferring one arbitrarily — first match by key order wins.
#
# A nil language passes through as a nil bucket — callers reading history for
# a response whose exercise is missing get no bucket rather than an exception.
class ConceptBucket
  ARCHITECTURE   = "architecture".freeze
  PLAN_REVIEW    = "plan_review".freeze
  AMBIGUITY_HUNT = "ambiguity_hunt".freeze

  SPECIAL_BUCKETS = {
    ARCHITECTURE   => ARCHITECTURE,
    PLAN_REVIEW    => PLAN_REVIEW,
    AMBIGUITY_HUNT => AMBIGUITY_HUNT
  }.freeze

  def self.for(sections, language)
    Array(sections).each do |section|
      special = SPECIAL_BUCKETS[section.to_s]
      return special if special
    end
    language
  end

  # The closed vocabulary a bucket's concepts are drawn from — the counterpart
  # to .for, which says which bucket a section records under.
  #
  # Selection queries need this because a mastery row outlives its vocabulary:
  # a concept renamed or dropped leaves a row that matches `language: bucket`
  # forever, and it can never resolve (the generator is only offered vocabulary
  # concepts, ingest normalizes anything else to "other", and
  # ConceptMastery.record_review! skips "other"). Filtering on membership is
  # what keeps such a row from claiming a slot it can never use.
  #
  # Every bucket .for can return is a LANGUAGE_CONFIG key, so a miss is a
  # bucket that escaped that mapping — fetch raises rather than yielding an
  # empty list, which a caller would read as "nothing is due" instead of a bug.
  def self.vocabulary_for(bucket)
    AiService::LANGUAGE_CONFIG.fetch(bucket).fetch(:concepts)
  end
end
