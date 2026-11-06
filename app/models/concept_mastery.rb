# Design notes: docs/code-notes/app/models/concept_mastery.md
class ConceptMastery < ApplicationRecord
  belongs_to :user

  enum :tier, { standard: 0, reduced: 1, paused: 2 }, prefix: true

  # Every selection query goes through here: filtering on `language:` alone keeps dead-concept rows due (#97).
  scope :in_bucket, ->(bucket) { where(language: bucket, concept: ConceptBucket.vocabulary_for(bucket)) }
  scope :in_buckets, ->(buckets) { buckets.map { |bucket| in_bucket(bucket) }.reduce(none, :or) }
  scope :drilling, -> { where.not(drilled_at: nil) }
  scope :reconciling, -> { where.not(review_reconciliation: {}) }
  scope :due_for_retention_check, -> { where.not(next_retention_check_on: nil).where(next_retention_check_on: ..Date.current) }

  AI_RATING_RANK = { "beginner" => 0, "developing" => 1, "solid" => 2, "strong" => 3 }.freeze
  INITIATE_RECONCILIATION = true

  # Capped at 60 days, where a re-check stops measuring retention; never derive this from vocabulary size (#98).
  RETENTION_INITIAL_INTERVAL_DAYS = 7
  RETENTION_GROWTH_FACTOR         = 2
  RETENTION_MAX_INTERVAL_DAYS     = 60
  RETENTION_OVERDUE_THRESHOLD_MULTIPLIER = 1

  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: [ :user_id, :language ] }

  # The caller holds user then response locks and saves the response in this same transaction.
  def self.record_review!(response, sections:, apply_session_countdown:, previous_review_keys:, initiate: INITIATE_RECONCILIATION)
    return unless response.submitted?

    Time.use_zone(response.user.effective_time_zone) do
      practice = PracticePolicyMode.active?(response.user)
      reconcile = reconciliation_active?(response.user, initiate: initiate)
      receipt = response.mastery_receipt(previous_review_keys: previous_review_keys, policy: practice ? 2 : 1) if reconcile || practice
      accepted = receipt ? sections - receipt.fetch("legacy_sections") - receipt.fetch("processed_sections") : sections
      next if accepted.empty?

      contributions = daily_contributions(response, accepted, receipt)
      skips = skipped_checks(response, accepted)
      countdown = apply_session_countdown && (accepted & response.assessed_adaptation_sections).any? && !receipt&.fetch("session_counted")
      rows = locked_rows(response.user, contributions, skips, countdown: countdown, reconcile: reconcile)
      apply_batch(response, rows, contributions, skips, countdown: countdown, receipt: receipt)
      receipt["processed_sections"] |= accepted if receipt
      response.mastery_application = receipt if receipt
    end
  end

  def self.reconciliation_active?(user, initiate:)
    uncached do
      receipts = user.daily_responses.where.not(mastery_application: {})
      enrolled = receipts.exists?
      DailyResponse.decode_mastery_application(receipts.pick(:mastery_application)) if enrolled
      initiate || enrolled || user.concept_masteries.reconciling.exists?
    end
  end
  private_class_method :reconciliation_active?

  def self.daily_contributions(response, accepted, receipt)
    all_accepted = receipt ? receipt.fetch("processed_sections") | accepted : accepted
    DailyEvidence.for(response, accepted_sections: all_accepted, legacy_sections: receipt ? receipt.fetch("legacy_sections") : [],
      policy: receipt&.fetch("policy", 1) || 1)
      .select { |entry| accepted_for(response, entry, accepted).any? }
  end
  private_class_method :daily_contributions

  def self.accepted_for(response, entry, accepted)
    return [] unless response.concept_tags.is_a?(Hash)

    accepted.select do |key|
      response.concept_tags[key] == entry.concept && ConceptBucket.for(key, response.daily_exercise.language) == entry.bucket
    end
  end
  private_class_method :accepted_for

  def self.skipped_checks(response, sections)
    return [] unless response.concept_tags.is_a?(Hash)

    answered = response.answered_concept_tags.select { |section, _| response.mastery_evidence?(section) }.values
    response.concept_tags.slice(*(sections & response.section_keys)).filter_map do |section, concept|
      next unless response.section_reviewed?(section) && !answered.include?(concept)

      response.mastery_tag(section)
    end.uniq
  end
  private_class_method :skipped_checks

  def self.locked_rows(user, contributions, skips, countdown:, reconcile:)
    scope = user.concept_masteries
    selected = scope.none
    selected = selected.or(scope.tier_paused) if countdown
    selected = selected.or(scope.reconciling) if reconcile
    (contributions.map { |entry| [ entry.bucket, entry.concept ] } | skips).each do |bucket, concept|
      selected = selected.or(scope.where(language: bucket, concept: concept))
    end
    rows = selected.order(:id).lock.to_a
    rows.each { |row| Reconciliation.decode(row.review_reconciliation) }
    contributions.each do |entry|
      next if rows.any? { |row| row.language == entry.bucket && row.concept == entry.concept }

      rows << scope.new(language: entry.bucket, concept: entry.concept)
    end
    rows
  end
  private_class_method :locked_rows

  def self.apply_batch(response, rows, contributions, skips, countdown:, receipt:)
    clocks = { "work_on" => response.date.iso8601, "reviewed_on" => Date.current.iso8601,
      "occurred_at" => Time.current.utc.iso8601(6) }
    if countdown
      rows.select { |row| row.persisted? && (row.tier_paused? || row.review_reconciliation != {}) }.each do |row|
        row.apply_mastery_operation("type" => "session", "response_id" => response.id)
      end
      receipt["session_counted"] = true if receipt
    end
    apply_skips(response, rows, skips, clocks, receipt)
    contributions.each do |entry|
      row = rows.find { |candidate| candidate.language == entry.bucket && candidate.concept == entry.concept }
      operation = clocks.merge("type" => "review", "response_id" => response.id,
        "sections" => entry.sections, "pending_sections" => receipt ? entry.pending_sections : [])
      operation["policy"] = 2 if receipt&.fetch("policy", 1) == 2
      row.apply_mastery_operation(operation)
    end
    rows.each { |row| row.save! if row.changed? }
  end
  private_class_method :apply_batch

  def self.apply_skips(response, rows, skips, clocks, receipt)
    skips -= receipt.fetch("skip_attempts") if receipt
    skips.each do |bucket, concept|
      row = rows.find { |candidate| candidate.language == bucket && candidate.concept == concept }
      row&.apply_mastery_operation(clocks.slice("work_on", "reviewed_on").merge("type" => "skip", "response_id" => response.id))
    end
    receipt["skip_attempts"] |= skips if receipt
  end
  private_class_method :apply_skips

  # Manual callers hold the user lock and lock their concrete targets in ascending ID order.
  def apply_mastery_operation(operation)
    result = Reconciliation.apply(current: Reconciliation.snapshot(self), journal: review_reconciliation, operation: operation)
    assign_attributes(result.state.merge("review_reconciliation" => result.journal))
  end
end
