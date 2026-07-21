class DailyResponse < ApplicationRecord
  belongs_to :user
  belongs_to :daily_exercise

  enum :rating, { too_easy: 0, right_level: 1, too_hard: 2 }, prefix: true

  SELF_RATING_LABELS = { "too_easy" => "too easy", "right_level" => "just right", "too_hard" => "too hard" }.freeze

  AI_RATING_FAVORABLE   = %w[solid strong].freeze
  AI_RATING_UNFAVORABLE = %w[beginner developing].freeze

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

  def self_rating_label       = SELF_RATING_LABELS[rating]
  def self_rating_favorable?  = rating_right_level? || rating_too_easy?
  def self_rating_unfavorable? = rating_too_hard?

  def ai_rating_for(section)        = ai_review&.dig(section.to_s, "rating")
  def ai_rating_favorable?(section)   = AI_RATING_FAVORABLE.include?(ai_rating_for(section))
  def ai_rating_unfavorable?(section) = AI_RATING_UNFAVORABLE.include?(ai_rating_for(section))

  # Answer keys with substantive content — same >10-char heuristic the
  # dashboard progress bar uses.
  def answered_sections
    answers.select { |_, v| v.to_s.strip.length > 10 }.keys
  end

  def completeness
    (answered_sections.size / 3.0 * 100).round
  end
end
