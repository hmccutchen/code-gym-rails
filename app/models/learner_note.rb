class LearnerNote < ApplicationRecord
  belongs_to :user
  belongs_to :daily_exercise

  MAX_TEXT_LENGTH = 1_000
  MAX_EXTRACT_ATTEMPTS = 2
  MAX_REPLY_ATTEMPTS = 2

  self.filter_attributes += %i[body explanation explanation_reply]

  validates :body, :explanation, length: { maximum: MAX_TEXT_LENGTH }
  validates :extract_attempts, numericality: { only_integer: true, in: 0..MAX_EXTRACT_ATTEMPTS }
  validates :reply_attempts, numericality: { only_integer: true, in: 0..MAX_REPLY_ATTEMPTS }
end
