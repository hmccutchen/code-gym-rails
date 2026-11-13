class ConceptReference < ApplicationRecord
  REFERENCE_FIELDS = %w[tagline explanation code_example senior_lens].freeze
  GUIDE_FIELDS     = %w[guide_plain_language guide_worked_example guide_pitfalls].freeze
  LADDER_FIELD_FOR = KindDifficulty::LEVELS.index_with { |level| "ladder_#{level}" }.freeze
  LADDER_FIELDS    = LADDER_FIELD_FOR.values.freeze
  MAX_LADDER_RUNG_LENGTH = 300

  belongs_to :user, optional: true

  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: %i[user_id language] }

  # A row with no user is the shared one, read as a fallback until L5 (docs/decisions/learn-content-per-user.md).
  scope :visible_to, ->(user) { where(user_id: [ nil, user.id ]) }

  def self.for(user, concept:, language:)
    seen_by(user, concept: concept, language: language)[[ concept, language ]]
  end

  def self.seen_by(user, **conditions)
    visible_to(user).where(conditions).sort_by { |reference| reference.user_id ? 1 : 0 }
                    .index_by { |reference| [ reference.concept, reference.language ] }
  end

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
    usable_lesson.present?
  end

  def usable_lesson
    ConceptLesson.from_provider(lesson)
  end

  def fully_written?
    complete? && lesson?
  end
end
