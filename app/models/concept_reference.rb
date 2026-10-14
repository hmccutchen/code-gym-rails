class ConceptReference < ApplicationRecord
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
end
