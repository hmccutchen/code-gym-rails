# Language-independent kinds record under their own bucket; a nil language passes through as a nil bucket.
class ConceptBucket
  ARCHITECTURE       = "architecture".freeze
  PLAN_REVIEW        = "plan_review".freeze
  AMBIGUITY_HUNT     = "ambiguity_hunt".freeze
  PSEUDOCODE_TO_CODE = "pseudocode_to_code".freeze

  SPECIAL_BUCKETS = {
    ARCHITECTURE       => ARCHITECTURE,
    PLAN_REVIEW        => PLAN_REVIEW,
    AMBIGUITY_HUNT     => AMBIGUITY_HUNT,
    PSEUDOCODE_TO_CODE => PSEUDOCODE_TO_CODE
  }.freeze

  LANGUAGE_INDEPENDENT = SPECIAL_BUCKETS.values.freeze

  # Reads the setting, never User#language_for_today, so a library does not change with tomorrow's roll.
  def self.language_buckets_for(language)
    language == "mixed" ? DailyExercise::LANGUAGES : [ language ]
  end

  def self.slice_for(language)
    language_buckets_for(language) + LANGUAGE_INDEPENDENT
  end

  def self.for(sections, language)
    Array(sections).each do |section|
      special = SPECIAL_BUCKETS[section.to_s]
      return special if special
    end
    language
  end

  # Raises on a miss rather than returning [], which a caller would read as "nothing is due".
  def self.vocabulary_for(bucket)
    ConceptVocabulary.for_language(bucket)
  end
end
