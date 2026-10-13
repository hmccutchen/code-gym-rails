class ConceptReference < ApplicationRecord
  # Ignored until every running process has stopped reading it; a later migration drops it.
  self.ignored_columns += [ "featured_on" ]

  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: :language }

  # Derived from the field list; a partly blank guide answers false so the row is regenerated whole.
  def guide?
    AiService::CONCEPT_GUIDE_FIELDS.all? { |field| public_send(field).present? }
  end

  def ladder?
    AiService::CONCEPT_LADDER_FIELDS.all? { |field| public_send(field).present? }
  end

  def complete?
    guide? && ladder?
  end

  # Kept out of complete? so the ladder poll and LadderCoverage never wait on a lesson.
  def lesson?
    lesson.present?
  end

  def fully_written?
    complete? && lesson?
  end

  # Truncated on read as well as bounded on write, like DailyResponse.usable_difficulty.
  def self.ladder_rungs(bucket:, concepts:, level:)
    field = AiService::LADDER_FIELD_FOR.fetch(level)

    where(language: bucket, concept: concepts).select(&:ladder?).to_h do |reference|
      [ reference.concept, reference.public_send(field).truncate(AiService::MAX_LADDER_RUNG_LENGTH) ]
    end
  end
end
