class DailyExercise < ApplicationRecord
  belongs_to :user
  has_one    :daily_response, dependent: :destroy

  # Concrete, generatable languages only -- excludes "mixed", which is a
  # per-user meta-preference (see User::LANGUAGES) that User#language_for_today
  # always resolves down to one of these before a DailyExercise is created or
  # regenerated. Persisting "mixed" here would let an invalid value flow back
  # into AiService#generate_exercise via DailyExercisesController#regenerate.
  LANGUAGES = %w[ruby_rails javascript].freeze

  validates :date, :problem_set, :generated_at, presence: true
  validates :date, uniqueness: { scope: :user_id }
  validates :language, inclusion: { in: LANGUAGES }

  scope :for_date, ->(d = Date.current) { where(date: d) }

  # Convenience accessors into the JSONB problem_set blob
  def code_review  = problem_set["code_review"]&.with_indifferent_access
  def pattern      = problem_set["pattern"]&.with_indifferent_access
  def challenge    = problem_set["challenge"]&.with_indifferent_access
end
