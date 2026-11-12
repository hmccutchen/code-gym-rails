class DailyExercise < ApplicationRecord
  def practice_schedule
    return {} unless plan_notes.is_a?(Hash) && plan_notes.key?("practice_schedule")

    PracticeSchedule::Note.decode(plan_notes.fetch("practice_schedule"))
  end

  belongs_to :user
  has_one    :daily_response, dependent: :destroy
  has_one    :duck_thread, dependent: :delete
  has_many   :judge_solves, dependent: :destroy

  # Excludes "mixed": a stored "mixed" would flow back into generation through RegenerateExerciseJob.
  LANGUAGES = %w[ruby_rails javascript].freeze

  JOB_PICKUP_MARGIN = 60.seconds

  # One worst-case judged pass (draft, then judge) plus pickup; GenerationDeadline stops any call that would overrun it.
  REGENERATION_DEADLINE = (CallProfiles.worst_case_seconds_for("generate_exercise") +
                           CallProfiles.worst_case_seconds_for("judge_section")).seconds + JOB_PICKUP_MARGIN

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

  def coverage_shown
    plan_notes["coverage_reason"] if active_section_keys.include?(plan_notes["coverage"])
  end

  def planned_size
    size = plan_notes["size"] if plan_notes.is_a?(Hash)
    size if size.is_a?(Integer) && User::DAILY_SECTION_COUNTS.cover?(size)
  end

  def draft_scope = "#{id}-#{generated_at.strftime('%s%6N')}"

  def planned_by_setting? = plan_notes["size_reason"] == "setting"

  def planned_under_brake? = plan_notes["brake"] == true

  def daily_kinds = DailyKinds.recorded(plan_notes)

  def shared_pair = DailyKinds.shared_pair(daily_kinds)

  def shared_concept_shown?
    ExerciseSection.daily_sections_share?(problem_set, plan_notes["shared_concept"], daily: shared_pair)
  end

  # The single authority for section counts; never problem_set.keys, which can hold unrendered alternates.
  def active_section_keys
    ExerciseSection.resolved_keys(problem_set, daily: daily_kinds)
  end

  def adaptation_section_keys
    return [] unless problem_set.is_a?(Hash) && plan_notes.is_a?(Hash)

    active_section_keys.select { |key| ExerciseSection.for(key).adaptation_evidence?(problem_set[key]) }
  end

  def concepts_withheld_before_submission
    active_section_keys.filter_map do |key|
      section = problem_set[key]
      concept = section&.dig("concept")
      concept if concept.present? && concept != "other" && !ExerciseSection.for(key).concept_shown_before_submission?(section)
    end
  end

  def regeneration_offered?(response)
    !(response&.persisted? && response.reviewed?) && regenerated_at.nil? && !user.trial_ended?
  end

  def mark_opened!
    return if opened_at.present?

    self.class.where(id: id, opened_at: nil).update_all(opened_at: Time.current)
    self.opened_at = self.class.where(id: id).pick(:opened_at)
    clear_attribute_changes([ :opened_at ])
  end

  def with_response_locked
    transaction do
      lock!
      yield DailyResponse.lock.find_by(daily_exercise_id: id)
    end
  end
end
