# One turn in a per-section conversation about a completed review. A real table
# rather than jsonb because a thread needs to be ordered and queryable, not just
# displayed. Preserved through User#anonymize!, which anonymizes in place and
# never destroys — same treatment as answers and ai_review.
class ReviewFollowUp < ApplicationRecord
  belongs_to :daily_response

  enum :role, { user: 0, assistant: 1 }, prefix: true

  validates :section, :content, presence: true

  # :id as a tiebreaker: the user and assistant turns of one exchange are created
  # microseconds apart in the same transaction, and Postgres timestamp precision
  # can collide. created_at alone would then order them arbitrarily and could
  # render the answer above its question.
  scope :for_section, ->(section) { where(section: section).order(:created_at, :id) }
end
