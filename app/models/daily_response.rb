class DailyResponse < ApplicationRecord
  belongs_to :user
  belongs_to :daily_exercise

  enum :rating, { too_easy: 0, right_level: 1, too_hard: 2 }, prefix: true

  validates :date, uniqueness: { scope: :user_id }

  def submitted? = submitted_at.present?
  def reviewed?  = ai_review.present?

  def completeness
    filled = answers.count { |_, v| v.to_s.strip.length > 10 }
    (filled / 3.0 * 100).round
  end
end
