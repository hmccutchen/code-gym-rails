class ConceptReference < ApplicationRecord
  # Only buckets every user holds: LearnController#show 404s a bucket outside the viewer's own slice.
  FEATURABLE_BUCKETS = ConceptBucket::LANGUAGE_INDEPENDENT

  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: :language }

  scope :featurable, -> { where(language: FEATURABLE_BUCKETS) }

  # Picked lazily on the week's first load and read after; never generates. Nil when no featurable row exists.
  def self.featured(date = team_today)
    week = featured_week_of(date)
    find_by(featured_on: week) || claim_feature(week)
  end

  # Monday, so a weekend visit still shows the concept the working week began with.
  def self.featured_week_of(date)
    date.beginning_of_week(:monday)
  end

  # The team's day, never the viewer's: use_time_zone would otherwise give teammates different weeks.
  def self.team_today
    Time.find_zone!(User::DEFAULT_TIME_ZONE).today
  end

  # Savepoint so the unique index's RecordNotUnique rolls back only the stamp and the re-read can see the winner.
  def self.claim_feature(week)
    candidate = featurable.order(Arel.sql("featured_on ASC NULLS FIRST"), :id).first
    return if candidate.nil?

    transaction(requires_new: true) { candidate.update!(featured_on: week) }
    candidate
  rescue ActiveRecord::RecordNotUnique
    find_by(featured_on: week)
  end
  private_class_method :claim_feature

  # Derived from the field list; a partly blank guide answers false so the row is regenerated whole.
  def guide?
    AiService::CONCEPT_GUIDE_FIELDS.all? { |field| public_send(field).present? }
  end

  # Derived from the field list the same way #guide? is.
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

  # GenerateConceptReferenceJob skips a row on this.
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
