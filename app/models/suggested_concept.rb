class SuggestedConcept < ApplicationRecord
  STATUSES = %w[pending promoted dismissed].freeze

  belongs_to :reviewed_by, class_name: "User", optional: true

  # "architecture" is valid because it's a ConceptVocabulary language key, though not a language.
  validates :language, inclusion: { in: ConceptVocabulary.languages }
  validates :normalized_name, :display_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  # The only write entry point; skips "other", AiService's own catch-all.
  def self.record!(language:, name:)
    normalized = name.to_s.strip.downcase.squeeze(" ")
    return nil if normalized.blank? || normalized == "other"

    record_suggestion(language, normalized, name.to_s.strip)
  end

  def self.record_suggestion(language, normalized, display_name, attempt: 0)
    concept = find_or_initialize_by(language: language, normalized_name: normalized)

    if concept.new_record?
      now = Time.current
      concept.assign_attributes(
        display_name:  display_name,
        occurrences:   1,
        first_seen_at: now,
        last_seen_at:  now
      )
      concept.save!
    else
      where(id: concept.id).update_all([ "occurrences = occurrences + 1, last_seen_at = ?", Time.current ])
      concept.reload
    end

    concept
  rescue ActiveRecord::RecordNotUnique
    # A concurrent generation created the row first; retry once against it.
    raise if attempt.positive?
    record_suggestion(language, normalized, display_name, attempt: attempt + 1)
  end
  private_class_method :record_suggestion
end
