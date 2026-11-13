class ReviewFollowUp < ApplicationRecord
  belongs_to :daily_response

  enum :role, { user: 0, assistant: 1 }, prefix: true

  validates :section, :content, presence: true
end
