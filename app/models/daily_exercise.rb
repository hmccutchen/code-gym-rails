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

  def code_review       = problem_set["code_review"]&.with_indifferent_access
  def pattern            = problem_set["pattern"]&.with_indifferent_access
  def challenge          = problem_set["challenge"]&.with_indifferent_access
  def architecture       = problem_set["architecture"]&.with_indifferent_access
  def security_review    = problem_set["security_review"]&.with_indifferent_access
  def parsons_problem    = problem_set["parsons_problem"]&.with_indifferent_access

  # Which third-section shape this exercise's problem_set actually holds.
  # Replaces the ad hoc `arch ? "architecture" :
  # "challenge"` pattern that build_review_prompt used before a third shape
  # (security_review) existed.
  #
  # Checked on the value's shape, not `problem_set.key?(key)`. A provider can
  # emit a third key holding null or a bare string alongside the real section;
  # resolving to it would hand build_review_prompt a section whose `["title"]`
  # raises. The earlier `key?` form of this method did exactly that, and the
  # per-key readers it replaced (`problem_set["architecture"]&.with_indifferent_access`)
  # raised outright on a non-Hash value rather than falling through.
  def third_key
    ExerciseSection.thirds.map(&:key).find { |key| problem_set[key].is_a?(Hash) } || "challenge"
  end
end
