class DailyExercise < ApplicationRecord
  belongs_to :user
  has_one    :daily_response, dependent: :destroy
  has_one    :duck_thread, dependent: :delete

  # Excludes "mixed": a stored "mixed" would flow back into generation through RegenerateExerciseJob.
  LANGUAGES = %w[ruby_rails javascript].freeze

  JOB_PICKUP_MARGIN = 60.seconds

  # One worst-case judged pass (draft, then judge) plus pickup; GenerationDeadline stops any call that would overrun it.
  REGENERATION_DEADLINE = (AiProvider.worst_case_seconds_for("generate_exercise") +
                           AiProvider.worst_case_seconds_for("judge_section")).seconds + JOB_PICKUP_MARGIN

  WRITE_MARGIN = 60.seconds

  REGENERATION_STALE_AFTER = REGENERATION_DEADLINE + WRITE_MARGIN

  include Claimable
  claim :regenerating, column: :regenerating_since, stale_after: REGENERATION_STALE_AFTER

  validates :date, :problem_set, :generated_at, presence: true
  validates :date, uniqueness: { scope: :user_id }
  validates :language, inclusion: { in: LANGUAGES }

  scope :for_date, ->(d = Date.current) { where(date: d) }

  def self.planned_size_before(date)
    where(date: ...date).where("plan_notes ? 'size'").order(date: :desc).pick(Arel.sql("(plan_notes->>'size')::integer"))
  end

  def code_review       = problem_set["code_review"]&.with_indifferent_access
  def pattern            = problem_set["pattern"]&.with_indifferent_access
  def challenge          = problem_set["challenge"]&.with_indifferent_access
  def architecture       = problem_set["architecture"]&.with_indifferent_access
  def security_review    = problem_set["security_review"]&.with_indifferent_access
  def parsons_problem    = problem_set["parsons_problem"]&.with_indifferent_access
  def plan_review        = problem_set["plan_review"]&.with_indifferent_access
  def ambiguity_hunt     = problem_set["ambiguity_hunt"]&.with_indifferent_access

  def coverage_shown
    plan_notes["coverage_reason"] if active_section_keys.include?(plan_notes["coverage"])
  end

  def planned_size = plan_notes["size"]

  def draft_scope = "#{id}-#{generated_at.strftime('%s%6N')}"

  def planned_size_with_coverage
    planned_size && planned_size + (plan_notes["coverage"] ? 1 : 0)
  end

  def planned_by_setting? = plan_notes["size_reason"] == "setting"

  def planned_under_brake? = plan_notes["brake"] == true

  def daily_kinds = DailyKinds.recorded(plan_notes)

  def shared_concept_shown?
    ExerciseSection.daily_sections_share?(problem_set, plan_notes["shared_concept"], daily: daily_kinds)
  end

  # The single authority for section counts; never problem_set.keys, which can hold unrendered alternates.
  def active_section_keys
    ExerciseSection.resolved_keys(problem_set, daily: daily_kinds)
  end

  def regeneration_offered?(response)
    !(response&.persisted? && response.reviewed?) && regenerated_at.nil? && !user.trial_ended?
  end

  def with_response_locked
    transaction do
      lock!
      yield DailyResponse.lock.find_by(daily_exercise_id: id)
    end
  end
end
