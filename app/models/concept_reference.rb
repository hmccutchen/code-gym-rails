class ConceptReference < ApplicationRecord
  REFERENCE_FIELDS = %w[tagline explanation code_example senior_lens].freeze
  GUIDE_FIELDS     = %w[guide_plain_language guide_worked_example guide_pitfalls].freeze
  LADDER_FIELD_FOR = KindDifficulty::LEVELS.index_with { |level| "ladder_#{level}" }.freeze
  LADDER_FIELDS    = LADDER_FIELD_FOR.values.freeze
  WRITTEN_FIELDS   = (REFERENCE_FIELDS + GUIDE_FIELDS + LADDER_FIELDS + [ "lesson" ]).freeze
  MAX_LADDER_RUNG_LENGTH = 300

  belongs_to :user

  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: %i[user_id language] }

  scope :visible_to, ->(user) { where(user_id: user.id) }

  def self.for(user, concept:, language:)
    find_by(user_id: user.id, concept: concept, language: language)
  end

  def self.seen_by(user, **conditions)
    visible_to(user).where(conditions).index_by { |reference| [ reference.concept, reference.language ] }
  end

  def self.missing_for(user, pairs)
    return [] if pairs.empty?

    seen = seen_by(user, concept: pairs.map(&:first).uniq, language: pairs.map(&:last).uniq)
    pairs.reject { |pair| seen.key?(pair) }
  end

  # Any user's row counts: the admin promote check asks only whether a concept was ever written up, and shows no text.
  def self.written_up?(language:, concept:)
    exists?(language: language, concept: concept)
  end

  def self.written_up_keys(languages:)
    where(language: languages).distinct.pluck(:language, :concept).to_set
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
