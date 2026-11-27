class ExerciseAddition < ApplicationRecord
  STATUSES = %w[queued running succeeded failed].freeze

  belongs_to :daily_exercise, inverse_of: :exercise_additions

  validates :request_uuid, :date, presence: true
  validates :draft_scope, format: { with: DailyExercise::DRAFT_SCOPE_FORMAT }
  validates :kind, inclusion: { in: ->(_addition) { ExerciseSection.keys } }
  validates :status, inclusion: { in: STATUSES }
end
