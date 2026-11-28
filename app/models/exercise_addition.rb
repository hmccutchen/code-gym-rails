class ExerciseAddition < ApplicationRecord
  STATUSES = %w[queued running succeeded failed].freeze
  UUID_FORMAT = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i

  belongs_to :daily_exercise, inverse_of: :exercise_additions

  include Claimable
  claim :executing, column: :claimed_at, stale_after: DailyExercise::REGENERATION_STALE_AFTER

  scope :active, -> { where(status: %w[queued running]) }

  validates :request_uuid, format: { with: UUID_FORMAT }
  validates :date, presence: true
  validates :draft_scope, format: { with: DailyExercise::DRAFT_SCOPE_FORMAT }
  validates :kind, inclusion: { in: ->(_addition) { ExerciseSection.keys } }
  validates :status, inclusion: { in: STATUSES }

  def self.available_kinds(user, exercise)
    keys = exercise.active_section_keys
    return [] if keys.size >= ExerciseSection::MAX_SECTIONS

    existing = keys.map { |key| ExerciseSection.for(key) }
    KindPreferences.offered_to(user).reject do |kind|
      exercise.problem_set.key?(kind.key) || DailyKinds.conflict(kind, existing)
    end
  end

  def expired?
    case status
    when "queued" then created_at + DailyExercise::JOB_PICKUP_MARGIN <= Time.current
    when "running" then claimed_at.nil? || claimed_at + DailyExercise::REGENERATION_STALE_AFTER <= Time.current
    else false
    end
  end

  def expire!
    return false unless expired?

    update!(status: "failed", claimed_at: nil)
  end

  def claim_once!
    return unless status == "queued" && claimed_at.nil? && !expired?

    token = claim_executing!(status: "queued", claimed_at: nil)
    update!(status: "running") if token
    token
  end

  def fail_queued!
    self.class.where(id: id, status: "queued", claimed_at: nil).update_all(status: "failed", updated_at: Time.current) == 1
  end

  def fail_claim!(token)
    return false unless token

    self.class.where(id: id, status: "running", claimed_at: token)
      .update_all(status: "failed", claimed_at: nil, updated_at: Time.current) == 1
  end
end
