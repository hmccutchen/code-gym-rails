class LearnerItem < ApplicationRecord
  belongs_to :user

  KINDS = %w[term misconception concept].freeze
  STATUSES = %w[open used dismissed expired].freeze
  EVIDENCE_SOURCES = %w[duck answer note explanation].freeze
  SECTIONLESS_SOURCES = %w[note].freeze
  MAX_OPEN = 5
  MAX_NEW_PER_DAY = 3
  MAX_EARLIER_LABELS = 20
  EARLIER_LABELS_PER_CONCEPT = 3
  RECENT_DAYS = 30
  MAX_EVIDENCE = 5
  MAX_CAME_UP_ON = 10
  MAX_LABEL_LENGTH = 160
  MAX_TERM_LENGTH = 40
  TERM_SHAPE = %r{\A[A-Za-z0-9 _+#./-]{1,#{MAX_TERM_LENGTH}}\z}
  EXPIRES_AFTER_EVIDENCE = 14.days
  LONGEST_LIFE = 42.days
  KEPT_AFTER_CLOSE = 90.days

  self.filter_attributes += %i[label term]

  normalizes :term, with: ->(term) { term.squish.presence }

  validates :concept, :bucket, :label, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :label, length: { maximum: MAX_LABEL_LENGTH }, format: { without: /[\r\n]/ }
  validates :term, format: { with: TERM_SHAPE }, if: :term_item?
  validates :term, absence: true, unless: :term_item?
  validates :expires_on, presence: true
  validate :concept_in_vocabulary, if: -> { new_record? || will_save_change_to_concept? || will_save_change_to_bucket? }
  validate :evidence_holds_references, if: -> { new_record? || will_save_change_to_evidence? }
  validate :came_up_on_holds_dates

  scope :expired_after_close, ->(today = Date.current) { where.not(status: "open").where(closed_on: ...(today - KEPT_AFTER_CLOSE)) }

  def self.expiry_for(newest_evidence_on:, created_on:)
    [ newest_evidence_on + EXPIRES_AFTER_EVIDENCE, created_on + LONGEST_LIFE ].min
  end

  def self.merge!(user, items, set_date:, still_there:) = Merge.call(user, items, set_date: set_date, still_there: still_there)

  def self.under_owner_lock(user)
    transaction do
      owner = User.lock.find_by(id: user.id)
      next :account_gone if owner.nil? || owner.anonymized?

      yield owner, Time.current.in_time_zone(owner.effective_time_zone).to_date
    end
  end

  def self.dismiss!(user, id)
    under_owner_lock(user) do |owner, today|
      expire_overdue!(owner, today: today)
      item = owner.learner_items.find_by(id: id)
      next :missing unless item
      next :closed unless item.status == "open"

      item.update!(status: "dismissed", closed_on: today)
      :dismissed
    end
  end

  def self.remove!(user, id)
    under_owner_lock(user) { |owner| owner.learner_items.where(id: id).delete_all.positive? ? :removed : :missing }
  end

  def self.listed_open(user, today:) = user.learner_items.where(status: "open", expires_on: today..).order(:created_at, :id)

  def self.recently_dismissed(user, today:)
    user.learner_items.where(status: "dismissed", closed_on: (today - RECENT_DAYS)..).order(closed_on: :desc, id: :desc)
  end

  def self.open_by_key(user) = user.learner_items.where(status: "open").index_by(&:matching_key)

  def self.expire_overdue!(user, today:)
    user.learner_items.where(status: "open", expires_on: ...today)
        .update_all([ "status = 'expired', closed_on = expires_on, updated_at = ?", Time.current ])
  end

  def self.displace_past_limit!(user, today:)
    open = user.learner_items.where(status: "open").sort_by { |item| [ item.newest_evidence_on, item.created_at, item.id ] }
    open.first([ open.size - MAX_OPEN, 0 ].max).each { |item| item.update!(status: "expired", closed_on: today) }
  end

  # The caller holds the user row lock, as every writer of items does.
  def self.forget_citing!(user, date:, sources:)
    cited = sources.map { |source| [ { "date" => date.iso8601, "source" => source } ].to_json }
    user.learner_items.where("evidence @> ANY (ARRAY[?]::jsonb[])", cited).delete_all
  end

  def self.prompt_values(item) = { concept: item.concept, bucket: item.bucket, kind: item.kind, term: item.term, label: item.label }

  def self.open_for_prompt(user) = user.learner_items.where(status: "open").order(:id).map { |item| prompt_values(item) }

  def self.earlier_labels(user, set_date:)
    closed = user.learner_items.where.not(status: "open").where(closed_on: (set_date - RECENT_DAYS)..).order(closed_on: :desc, id: :desc)
    capped = closed.group_by { |item| [ item.concept, item.bucket ] }.values.flat_map { |same| same.first(EARLIER_LABELS_PER_CONCEPT) }
    capped.sort_by { |item| [ -item.closed_on.jd, -item.id ] }.first(MAX_EARLIER_LABELS)
          .map { |item| prompt_values(item).merge(status: item.status, date: item.closed_on.iso8601) }
  end

  def self.matching_key(concept:, bucket:, kind:, term: nil)
    [ concept, bucket, kind, kind == "term" ? term.to_s.squish.downcase : "" ]
  end

  def matching_key = self.class.matching_key(concept: concept, bucket: bucket, kind: kind, term: term)

  def term_item? = kind == "term"

  def newest_evidence_on = evidence.map { |reference| Date.iso8601(reference["date"]) }.max

  def first_reference = evidence.min_by { |reference| reference["date"] }

  def came_up_dates = came_up_on.map { |date| Date.iso8601(date) }.sort

  private

  def concept_in_vocabulary
    errors.add(:concept, "is not in that vocabulary") unless ConceptBucket.valid_identity?(concept: concept, bucket: bucket)
  end

  def evidence_holds_references
    return if evidence.is_a?(Array) && evidence.size <= MAX_EVIDENCE && evidence.all? { |reference| reference_shaped?(reference) }

    errors.add(:evidence, "must be at most #{MAX_EVIDENCE} references of a date, a source and its section")
  end

  def reference_shaped?(reference)
    return false unless reference.is_a?(Hash) && iso_date?(reference["date"]) && EVIDENCE_SOURCES.include?(reference["source"])

    expected_keys = SECTIONLESS_SOURCES.include?(reference["source"]) ? %w[date source] : %w[date source section]
    reference.keys.sort == expected_keys.sort && (!reference.key?("section") || ExerciseSection.keys.include?(reference["section"]))
  end

  def came_up_on_holds_dates
    return if came_up_on.is_a?(Array) && came_up_on.size <= MAX_CAME_UP_ON && came_up_on.uniq.size == came_up_on.size &&
              came_up_on.all? { |date| iso_date?(date) }

    errors.add(:came_up_on, "must be at most #{MAX_CAME_UP_ON} distinct dates")
  end

  def iso_date?(value)
    value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(value).present?
  rescue Date::Error
    false
  end
end
