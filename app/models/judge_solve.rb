# Design notes: docs/code-notes/app/models/judge_solve.md
class JudgeSolve < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :daily_exercise, optional: true

  SOURCES = %w[live replay synthetic].freeze
  REVERT_REASONS = %w[solve_mismatch judge_rejected judge_failed].freeze
  NEVER_SHOWN_REASONS = %w[replaced_by_retry section_dropped].freeze
  MATCHED_CALLS = %w[key_right both_wrong both_defensible].freeze
  MISMATCH_CALLS = %w[key_right judge_right both_defensible].freeze
  UNCALLED = "uncalled".freeze
  WITHHELD_SECTION = %i[daily_exercise_id section set_generated_at].freeze

  SOLVE_FIELDS = %i[
    section attempt edit_check rung locked concept judged_section
    judge_status judge_pick key_better matched unsolved_reason unsolved_detail
    edit_reverted revert_reason judge_provider judge_model shipped never_shown_reason
  ].freeze

  APP_REVISION_ENV = "RAILWAY_GIT_COMMIT_SHA".freeze

  class RecordError < StandardError; end

  validates :revert_reason, inclusion: { in: REVERT_REASONS }, allow_nil: true
  validate :human_call_fits_matched

  before_save :stamp_section_digest, if: :judged_section_changed?
  before_update :stamp_human_called_at, if: :human_call_changed?

  scope :readable, -> {
    where(source: "synthetic")
      .or(where.not(never_shown_reason: nil))
      .or(where(section_review_exists))
  }

  scope :withheld, -> { where.not(id: readable.select(:id)) }

  def self.withheld_section_count
    unscoped.from(withheld.group(*WITHHELD_SECTION).select("1"), :sections).count
  end

  def self.section_review_exists
    responses = DailyResponse.arel_table
    DailyResponse.joins(:daily_exercise)
                 .where(responses[:daily_exercise_id].eq(arel_table[:daily_exercise_id]))
                 .where(DailyExercise.arel_table[:generated_at].eq(arel_table[:set_generated_at]))
                 .where(DailyResponse.section_reviewed_condition(arel_table[:section]))
                 .arel.exists
  end

  def self.calls_for(matched)
    case matched
    when true  then MATCHED_CALLS
    when false then MISMATCH_CALLS
    else []
    end
  end

  def self.app_revision = ENV[APP_REVISION_ENV].presence

  def self.record!(exercise, solves, source: "live", draft_model: nil, app_revision: self.app_revision)
    write_solves!(solves, user_id: exercise.user_id, daily_exercise: exercise, set_generated_at: exercise.generated_at,
                          source: source, draft_model: draft_model, app_revision: app_revision)
  end

  def self.record_synthetic!(solves, draft_model: nil, app_revision: self.app_revision)
    write_solves!(solves, source: "synthetic", draft_model: draft_model, app_revision: app_revision)
  end

  def self.write_solves!(solves, stamps)
    transaction do
      solves.map { |solve| create!(SOLVE_FIELDS.index_with { |field| solve.public_send(field) }.merge(stamps)) }
    end
  rescue ActiveRecord::StatementInvalid, ActiveRecord::RecordInvalid => error
    raise RecordError, "judge_solves row refused: #{refusal_name(error)}", cause: nil
  end
  private_class_method :write_solves!

  def self.refusal_name(error)
    return error.record.errors.attribute_names.join(", ") if error.is_a?(ActiveRecord::RecordInvalid)

    result = error.cause.respond_to?(:result) ? error.cause.result : nil
    result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) ||
      result&.error_field(PG::Result::PG_DIAG_COLUMN_NAME) || error.class.name
  end
  private_class_method :refusal_name

  private

  def human_call_fits_matched
    return if human_call.nil? || self.class.calls_for(matched).include?(human_call)

    errors.add(:human_call, :inclusion, value: human_call)
  end

  def stamp_human_called_at
    self.human_called_at = Time.current
  end

  def stamp_section_digest
    self.section_digest = SectionDigest.call(judged_section)
  end
end
