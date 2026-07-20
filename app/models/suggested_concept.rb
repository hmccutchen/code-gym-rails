class SuggestedConcept < ApplicationRecord
  STATUSES = %w[pending promoted dismissed].freeze

  belongs_to :reviewed_by, class_name: "User", optional: true

  validates :language, inclusion: { in: AiService::LANGUAGE_CONFIG.keys }
  validates :normalized_name, :display_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  # The only write entry point for an off-vocabulary suggestion. Skips a
  # literal "other" — that's AiService's own catch-all, not a real suggestion.
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
      concept.update!(occurrences: concept.occurrences + 1, last_seen_at: Time.current)
    end

    concept
  rescue ActiveRecord::RecordNotUnique
    # A concurrent generation raced us to create the same row. Retry once
    # against the now-existing row instead of raising.
    raise if attempt.positive?
    record_suggestion(language, normalized, display_name, attempt: attempt + 1)
  end
  private_class_method :record_suggestion
end
