class ConceptReference < ApplicationRecord
  GUIDE_FIELDS     = %w[guide_plain_language guide_worked_example guide_pitfalls].freeze
  LADDER_FIELD_FOR = KindDifficulty::LEVELS.index_with { |level| "ladder_#{level}" }.freeze
  LADDER_FIELDS    = LADDER_FIELD_FOR.values.freeze

  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: :language }

  # Derived from the field list; a partly blank guide answers false so the row is regenerated whole.
  def guide?
    GUIDE_FIELDS.all? { |field| public_send(field).present? }
  end

  def ladder?
    LADDER_FIELDS.all? { |field| public_send(field).present? }
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
