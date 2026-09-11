class ConceptReference < ApplicationRecord
  # The day's featured concept is the one thing this app points every teammate
  # at by name, so it is drawn only from the buckets every user holds. A
  # language-vocabulary pick would be unreachable for a single-language user —
  # LearnController#show validates :bucket against that user's own slice — and
  # would show them a stack they do not work in.
  FEATURABLE_BUCKETS = ConceptBucket::LANGUAGE_INDEPENDENT

  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: :language }

  scope :featurable, -> { where(language: FEATURABLE_BUCKETS) }

  # Today's featured concept, picked on the first page load of the day that
  # asks for it and simply read on every one after. Lazy rather than scheduled:
  # nothing has to fire at midnight, and a Saturday behaves exactly like a
  # Tuesday because the only input is the date being asked about.
  #
  # Selects nothing and spends nothing — every field it renders was written by
  # the Learn tab's existing generation. Nil when no featurable row has been
  # written yet, which the callers render as no callout rather than an error.
  def self.featured(date = Date.current)
    find_by(featured_on: date) || claim_feature(date)
  end

  # Staleness order, longest-unfeatured first, with a never-featured row ahead
  # of every dated one — the same "unseen outranks stale" rule SectionRotation
  # applies to exercise kinds. Postgres sorts NULLs last on ASC, so NULLS FIRST
  # is what puts an unfeatured row at the head rather than the tail.
  #
  # The unique index on featured_on is the race guard: two first-visits landing
  # together both pass the read above, and the loser's write violates it rather
  # than stamping a second concept for the same day. Deliberately lighter than
  # the row lock the cost-bearing paths take — this picks a row to read, so the
  # loser re-reads the winner's pick and both visitors see one concept.
  def self.claim_feature(date)
    candidate = featurable.order(Arel.sql("featured_on ASC NULLS FIRST"), :id).first
    return if candidate.nil?

    candidate.update!(featured_on: date)
    candidate
  rescue ActiveRecord::RecordNotUnique
    find_by(featured_on: date)
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
end
