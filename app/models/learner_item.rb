class LearnerItem < ApplicationRecord
  belongs_to :user

  KINDS = %w[term misconception concept].freeze
  STATUSES = %w[open used dismissed expired].freeze
  EVIDENCE_SOURCES = %w[duck answer note explanation].freeze
  SECTIONLESS_SOURCES = %w[note].freeze
  MAX_OPEN = 5
  MAX_EVIDENCE = 5
  MAX_CAME_UP_ON = 10
  MAX_LABEL_LENGTH = 160
  TERM_SHAPE = %r{\A[A-Za-z0-9 _+#./-]{1,40}\z}
  EXPIRES_AFTER_EVIDENCE = 14.days
  LONGEST_LIFE = 42.days

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

  def self.expiry_for(newest_evidence_on:, created_on:)
    [ newest_evidence_on + EXPIRES_AFTER_EVIDENCE, created_on + LONGEST_LIFE ].min
  end

  def self.matching_key(concept:, bucket:, kind:, term: nil)
    [ concept, bucket, kind, kind == "term" ? term.to_s.squish.downcase : "" ]
  end

  def matching_key = self.class.matching_key(concept: concept, bucket: bucket, kind: kind, term: term)

  def term_item? = kind == "term"

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
