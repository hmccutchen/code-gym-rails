# Preserved through User#anonymize!, like answers and ai_review.
class ReviewFollowUp < ApplicationRecord
  belongs_to :daily_response

  enum :role, { user: 0, assistant: 1 }, prefix: true

  validates :section, :content, presence: true

  # :id breaks created_at ties, since an exchange's two turns can share a timestamp and render out of order.
  scope :for_section, ->(section) { where(section: section).order(:created_at, :id) }
end
