module ConceptReferencesHelper
  # concept_tags is always built from these three fixed section keys
  # (see ResponsesController#exercise_concept_tags), so an exposure query can
  # match the concept against each key's value directly in SQL rather than
  # loading every row and filtering in Ruby.
  CONCEPT_TAG_SECTIONS = %w[code_review pattern challenge].freeze

  # Exposure count for a concept = the number of the user's SUBMITTED responses
  # whose concept_tags values include the concept. Filters on submitted_at
  # because auto-saved drafts also populate concept_tags; counting bare rows
  # would inflate the count. Inclusive of the current response (the reference
  # only ever renders on an already-submitted response), so count == 1 means
  # first exposure. Each row is counted at most once, so a concept appearing in
  # two sections of one response is a single exposure.
  def concept_exposure_count(user, concept)
    conditions = CONCEPT_TAG_SECTIONS.map { |section| "concept_tags ->> ? = ?" }.join(" OR ")
    bindings   = CONCEPT_TAG_SECTIONS.flat_map { |section| [ section, concept ] }

    user.daily_responses
        .where.not(submitted_at: nil)
        .where(conditions, *bindings)
        .count
  end

  # For a response, returns one entry per distinct tagged concept that has a
  # cached ConceptReference in the response's language:
  #   [{ concept:, reference:, count: }, ...]
  # Concepts without a cached reference (not generated yet, "other", or an old
  # response with empty concept_tags) are skipped — the view renders nothing.
  def concept_references_for(response)
    language = response.daily_exercise.language
    concepts = response.concept_tags.values.compact.uniq

    concepts.filter_map do |concept|
      reference = ConceptReference.find_by(concept: concept, language: language)
      next unless reference
      { concept: concept, reference: reference, count: concept_exposure_count(response.user, concept) }
    end
  end
end
