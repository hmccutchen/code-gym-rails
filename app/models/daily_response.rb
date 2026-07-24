class DailyResponse < ApplicationRecord
  belongs_to :user, inverse_of: :daily_responses
  belongs_to :daily_exercise

  SELF_RATINGS = %w[too_easy right_level too_hard].freeze
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

  def self_rating_for(section) = section_ratings[section.to_s]
  def self_rating_favorable?(section)  = SELF_RATINGS[0, 2].include?(self_rating_for(section)) # too_easy / right_level
  def self_rating_unfavorable?(section) = self_rating_for(section) == "too_hard"
  def self_rating_label(section)       = SELF_RATING_LABELS[self_rating_for(section)]

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

  # improved_code is revealed only from a concept's SECOND exposure onward — the
  # first time a concept appears, the corrected answer stays hidden (mirrors the
  # attempt-gated teaching_note). Ungated for blank/"other" (no concept to track).
  def improved_code_visible?(section)
    concept = concept_tags[section.to_s]
    return true if concept.blank? || concept == "other"
    bucket = section.to_s == "architecture" ? "architecture" : daily_exercise.language
    user.concept_exposure_count(concept, bucket, on_or_before: date) >= 2
  end
end
