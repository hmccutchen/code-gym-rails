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

  def self.indexed_for(user, **conditions)
    user.concept_references.where(conditions).index_by { |reference| [ reference.concept, reference.language ] }
  end

  def self.missing_for(user, pairs)
    return [] if pairs.empty?

    owned = indexed_for(user, concept: pairs.map(&:first).uniq, language: pairs.map(&:last).uniq)
    pairs.reject { |pair| owned.key?(pair) }
  end

  # Any user's row counts: the admin promote check asks only whether a concept was ever written up, and shows no text.
  def self.written_up?(language:, concept:)
    exists?(language: language, concept: concept)
  end

  def self.find_for(concept:, language:)
    find_by(concept:, language:)
  end

  def self.written_up_keys(languages:)
    where(language: languages).distinct.pluck(:language, :concept).to_set
  end

  def self.wanted_write(own, ladder_asked:, refresh:, seen_version:)
    if ladder_asked && own&.reference_text?
      :ladder if ladder_wanted?(own, seen_version:)
    elsif write_wanted?(own, refresh:, seen_version:)
      :full
    end
  end

  def self.write_wanted?(own, refresh:, seen_version:)
    version_seen?(own, seen_version) && (own.nil? || (refresh && !own.fully_written?))
  end

  def self.ladder_wanted?(own, seen_version:)
    return false unless own&.ladder_addable?

    version_seen?(own, seen_version)
  end

  def self.complete_ladder?(fields)
    LADDER_FIELDS.all? { |field| fields[field].present? }
  end

  def self.write_for(user, concept:, language:, attributes:, refresh:, seen_version:)
    written = WRITTEN_FIELDS.index_with { |field| attributes[field] }

    with_owner_share_locked(user) do
      own = uncached { user.concept_references.find_for(concept:, language:) }
      next rewrite(own, written, refresh:, seen_version:) if own
      next :skipped unless write_wanted?(nil, refresh:, seen_version:)

      create!(written.merge("user_id" => user.id, "concept" => concept, "language" => language, "generation_version" => 1))
      :written
    end
  end

  def self.write_ladder_for(user, concept:, language:, ladder:, seen_version:)
    with_owner_share_locked(user) do
      own = uncached { user.concept_references.find_for(concept:, language:) }
      next :skipped unless own

      own.with_lock do
        next :skipped unless ladder_wanted?(own, seen_version:)

        own.update!(LADDER_FIELDS.index_with { |field| ladder[field] }.merge(generation_version: own.generation_version + 1))
        :written
      end
    end
  end

  # The owner is share-locked before the row, as AccountDeletion locks it, so a deleted account gets nothing.
  def self.with_owner_share_locked(user)
    User.transaction do
      next :account_deleted unless User.active.lock("FOR SHARE").exists?(id: user.id)

      yield
    end
  end
  private_class_method :with_owner_share_locked

  def self.version_seen?(own, seen_version)
    seen_version.nil? || seen_version == (own&.generation_version || 0)
  end
  private_class_method :version_seen?

  def self.rewrite(own, written, refresh:, seen_version:)
    own.with_lock do
      next :skipped unless write_wanted?(own, refresh:, seen_version:)

      own.update!(keeping_stored_ladder(written).merge(generation_version: own.generation_version + 1))
      :written
    end
  end
  private_class_method :rewrite

  def self.keeping_stored_ladder(written)
    complete_ladder?(written) ? written : written.except(*LADDER_FIELDS)
  end
  private_class_method :keeping_stored_ladder

  # Derived from the field list; a partly blank guide answers false so the row is regenerated whole.
  def guide?
    GUIDE_FIELDS.all? { |field| public_send(field).present? }
  end

  def reference_text?
    REFERENCE_FIELDS.all? { |field| public_send(field).present? }
  end

  def ladder?
    self.class.complete_ladder?(self)
  end

  def ladder_addable?
    reference_text? && !ladder?
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
