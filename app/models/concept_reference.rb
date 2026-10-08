class ConceptReference < ApplicationRecord
  # The week's featured concept is the one thing this app points every teammate
  # at by name, so it is drawn only from the buckets every user holds. A
  # language-vocabulary pick would be unreachable for a single-language user —
  # LearnController#show validates :bucket against that user's own slice — and
  # would show them a stack they do not work in.
  FEATURABLE_BUCKETS = ConceptBucket::LANGUAGE_INDEPENDENT

  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: :language }

  scope :featurable, -> { where(language: FEATURABLE_BUCKETS) }

  # This week's featured concept, picked on the first page load of the week
  # that asks for it and simply read on every one after. A week rather than a
  # day so a teammate who opens the app only a few times has time to read the
  # whole guide. Lazy rather than scheduled: nothing has to fire on Monday, and
  # the only input is the date being asked about.
  #
  # Selects nothing and spends nothing — every field it renders was written by
  # the Learn tab's existing generation. Nil when no featurable row has been
  # written yet, which the callers render as no callout rather than an error.
  def self.featured(date = team_today)
    week = featured_week_of(date)
    find_by(featured_on: week) || claim_feature(week)
  end

  # featured_on holds the Monday of the week a row was featured, so the unique
  # index allows one concept per week. Monday so a weekend visit still shows
  # the concept the working week began with.
  def self.featured_week_of(date)
    date.beginning_of_week(:monday)
  end

  # The TEAM's day, never the viewer's. ApplicationController wraps every action
  # in Time.use_zone(the current user's zone), so a bare Date.current here would
  # resolve per viewer: two teammates either side of Sunday midnight would ask
  # about different weeks, each stamp a row, and each get their own "this
  # week's concept" — which is precisely the one global pick this feature
  # exists to be, broken. The unique index cannot catch that, since the two
  # weeks genuinely differ.
  #
  # Resolved in the zone User already falls back to for a user who has not set
  # one — config/recurring.yml calls it the team default zone — rather than a
  # second constant of the same value that could later disagree with it. UTC
  # was the alternative and is worse here: it rolls the concept over on Sunday
  # evening for this team rather than at their midnight.
  def self.team_today
    Time.find_zone!(User::DEFAULT_TIME_ZONE).today
  end

  # Staleness order, longest-unfeatured first, with a never-featured row ahead
  # of every dated one — the same "unseen outranks stale" rule SectionRotation
  # applies to exercise kinds. Postgres sorts NULLs last on ASC, so NULLS FIRST
  # is what puts an unfeatured row at the head rather than the tail.
  #
  # The unique index on featured_on is the race guard: two first-visits landing
  # together both pass the read above, and the loser's write violates it rather
  # than stamping a second concept for the same week. Deliberately lighter than
  # the row lock the cost-bearing paths take — this picks a row to read, so the
  # loser re-reads the winner's pick and both visitors see one concept.
  #
  # A SAVEPOINT so the violation rolls back only the stamp. Without it the write
  # joins whatever transaction the caller already has open and aborts it, and
  # the recovery read below then raises PG::InFailedSqlTransaction instead of
  # returning the winner — the same reason PushSubscription.upsert and
  # User#carry_forward wrap theirs. Only RecordNotUnique can arise: featured_on
  # is enforced by the index alone, with no model validation to raise
  # RecordInvalid first the way `date` does on those two.
  def self.claim_feature(week)
    candidate = featurable.order(Arel.sql("featured_on ASC NULLS FIRST"), :id).first
    return if candidate.nil?

    transaction(requires_new: true) { candidate.update!(featured_on: week) }
    candidate
  rescue ActiveRecord::RecordNotUnique
    find_by(featured_on: week)
  end
  private_class_method :claim_feature

  # The one answer to "does this row carry the Learn tab's guide". Rows
  # generated before the guide existed answer false, and so does one whose
  # guide the provider left partly blank — both are regenerated whole rather
  # than rendered half-populated. Derived from the field list rather than
  # naming the columns again, the way ConceptBucket derives its vocabulary from
  # AiService::LANGUAGE_CONFIG.
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

  # Kept apart from complete? so a row's guide and ladder read as they did
  # before lessons existed: the ladder status poll and LadderCoverage never
  # wait on a lesson.
  def lesson?
    lesson.present?
  end

  # Nothing left for a rewrite to add, which is what GenerateConceptReferenceJob
  # skips on.
  def fully_written?
    complete? && lesson?
  end

  # Truncated on read as well as bounded on write, the way
  # DailyResponse.usable_difficulty is applied both ways. No LIMIT: the unique
  # (concept, language) index and the vocabulary filter already bound the rows.
  def self.ladder_rungs(bucket:, concepts:, level:)
    field = AiService::LADDER_FIELD_FOR.fetch(level)

    where(language: bucket, concept: concepts).select(&:ladder?).to_h do |reference|
      [ reference.concept, reference.public_send(field).truncate(AiService::MAX_LADDER_RUNG_LENGTH) ]
    end
  end
end
