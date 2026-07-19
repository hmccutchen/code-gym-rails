module ConceptReferencesHelper
  # The fixed keys concept_tags is built from (ResponsesController#exercise_concept_tags),
  # which lets the exposure query match in SQL instead of filtering in Ruby.
  CONCEPT_TAG_SECTIONS = %w[code_review pattern challenge].freeze

  # How many of the user's submitted responses were tagged with the concept.
  # Drafts are excluded — they auto-save concept_tags before submission, which
  # would inflate the count. Counts the current (already-submitted) response
  # too, so 1 means first exposure; each response counts at most once.
  def concept_exposure_count(user, concept)
    conditions = CONCEPT_TAG_SECTIONS.map { |section| "concept_tags ->> ? = ?" }.join(" OR ")
    bindings   = CONCEPT_TAG_SECTIONS.flat_map { |section| [ section, concept ] }

    user.daily_responses
        .where.not(submitted_at: nil)
        .where(conditions, *bindings)
        .count
  end

  # One [{ concept:, reference:, count: }] entry per distinct tagged concept
  # that has a cached reference in the response's language. Concepts without a
  # cached reference are skipped, so old/untagged responses render nothing.
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
