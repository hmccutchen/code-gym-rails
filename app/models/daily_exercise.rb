class DailyExercise < ApplicationRecord
  belongs_to :user
  has_one    :daily_response, dependent: :destroy

  # Excludes "mixed": a stored "mixed" would flow back into generation through RegenerateExerciseJob.
  LANGUAGES = %w[ruby_rails javascript].freeze

  # Must exceed AiService::GENERATION_READ_TIMEOUT plus job pickup, or a healthy job looks abandoned.
  REGENERATION_STALE_AFTER = 6.minutes

  validates :date, :problem_set, :generated_at, presence: true
  validates :date, uniqueness: { scope: :user_id }
  validates :language, inclusion: { in: LANGUAGES }

  scope :for_date, ->(d = Date.current) { where(date: d) }

  # A row from before plans recorded a size is skipped rather than read as one.
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

  # nil when the plan added nothing or the added section is gone, so the dashboard never makes a false claim.
  def coverage_shown
    plan_notes["coverage_reason"] if active_section_keys.include?(plan_notes["coverage"])
  end

  # Before any coverage addition; nil on a row from before plans recorded it.
  def planned_size = plan_notes["size"]

  # CoverageException adds at most one section.
  def planned_size_with_coverage
    planned_size && planned_size + (plan_notes["coverage"] ? 1 : 0)
  end

  def planned_by_setting? = plan_notes["size_reason"] == "setting"

  def shared_concept_shown?
    ExerciseSection.fixed_sections_share?(problem_set, plan_notes["shared_concept"])
  end

  def regenerating?
    regenerating_since.present? && regenerating_since > REGENERATION_STALE_AFTER.ago
  end

  # Checked on the value's shape: a provider can emit a third key holding null or a string beside the real one.
  def third_key
    ExerciseSection.resolved_key(problem_set, ExerciseSection.thirds) || "challenge"
  end

  # No fallback kind: an exercise from before the fourth slot existed correctly answers nil.
  def fourth_key
    ExerciseSection.resolved_fourth_key(problem_set)
  end

  # The single authority for section counts; never problem_set.keys, which can hold unrendered alternates.
  def active_section_keys
    ExerciseSection.resolved_keys(problem_set)
  end
end
