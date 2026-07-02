class DailyExercise < ApplicationRecord
  belongs_to :user
  has_one    :daily_response, dependent: :destroy

  validates :date, :problem_set, :generated_at, presence: true
  validates :date, uniqueness: { scope: :user_id }

  scope :for_date, ->(d = Date.current) { where(date: d) }

  # Convenience accessors into the JSONB problem_set blob
  def code_review  = problem_set["code_review"]&.with_indifferent_access
  def pattern      = problem_set["pattern"]&.with_indifferent_access
  def challenge    = problem_set["challenge"]&.with_indifferent_access
end
