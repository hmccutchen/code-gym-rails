class DailyResponse < ApplicationRecord
  belongs_to :user
  belongs_to :daily_exercise

  enum :rating, { too_easy: 0, right_level: 1, too_hard: 2 }, prefix: true

  validates :date, uniqueness: { scope: :user_id }

  # Ordered field → label map for rendering ai_review sections — shared by the
  # shared/_ai_review partial and ReviewMailer so the copy lives in one place.
  # "rating" (badge) and "improved_code" (code block) render separately.
  AI_REVIEW_FIELDS = {
    "correct"          => "What you got right",
    "missed"           => "What you missed",
    "better_questions" => "Questions to ask yourself",
    "next_step"        => "Next step"
  }.freeze

  def submitted? = submitted_at.present?
  def reviewed?  = ai_review.present?

  # Answer keys with substantive content — same >10-char heuristic the
  # dashboard progress bar uses.
  def answered_sections
    answers.select { |_, v| v.to_s.strip.length > 10 }.keys
  end

  def completeness
    (answered_sections.size / 3.0 * 100).round
  end
end
