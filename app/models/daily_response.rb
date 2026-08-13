class DailyResponse < ApplicationRecord
  belongs_to :user, inverse_of: :daily_responses
  belongs_to :daily_exercise
  has_many :review_follow_ups, dependent: :destroy

  SELF_RATINGS = %w[too_easy right_level too_hard].freeze
  SELF_RATING_LABELS = { "too_easy" => "too easy", "right_level" => "just right", "too_hard" => "too hard" }.freeze

  AI_RATING_FAVORABLE   = %w[solid strong].freeze
  AI_RATING_UNFAVORABLE = %w[beginner developing].freeze

  # How many alternate framings a single section may accumulate. Enforced in
  # ResponsesController#explain_differently as well as in the view: the view
  # stops offering the button at the cap, but only the server bound holds
  # against a crafted request. Lives here, not on the controller, because it's
  # a property of the data (how many alternates a response may hold) that the
  # view partial also needs to read.
  MAX_ALTERNATES_PER_SECTION = 2

  # How many questions a user may ask about one section. Three exchanges is
  # enough to clear up a misunderstanding without the review becoming an
  # open-ended chat. Same rationale as MAX_ALTERNATES_PER_SECTION for living here.
  MAX_FOLLOW_UPS_PER_SECTION = 3

  # How many History entries render per page. Lives on the model rather than
  # HistoryController because #history_page needs the same number to work out
  # which page a given response lands on.
  HISTORY_PAGE_SIZE = 10

  validates :date, uniqueness: { scope: :user_id }

  scope :submitted, -> { where.not(submitted_at: nil) }

  # Ordered field → {label, list} map for rendering ai_review sections — shared by
  # the shared/_ai_review partial and ReviewMailer so the copy lives in one place.
  # `list: true` fields hold multiple discrete points and render as a real list;
  # next_step is deliberately one thing to study, so it stays a single string.
  # "rating" (badge) and "improved_code" (code block) render separately.
  AI_REVIEW_FIELDS = {
    "correct"          => { label: "What you got right",        list: true  },
    "missed"           => { label: "What you missed",           list: true  },
    "better_questions" => { label: "Questions to ask yourself", list: true  },
    "next_step"        => { label: "Next step",                 list: false }
  }.freeze

  # Reads a review field as a list of discrete points regardless of how it was
  # stored. Reviews generated before the schema moved to arrays hold a single
  # string; those render as a one-item list rather than being backfilled, since
  # ai_review is jsonb and old rows are still perfectly readable. A class method
  # rather than a helper because the mailer's text template needs it too, and
  # helpers aren't included in mailer views by default — same reason
  # AI_REVIEW_FIELDS lives here.
  def self.review_points(value)
    case value
    when Array then value.map { |v| v.to_s.strip }.reject(&:blank?)
    else            [ value.to_s.strip ].reject(&:blank?)
    end
  end

  # Same array-tolerance as review_points (a schema drift could return an Array
  # here too), but without stripping each entry: review_points' per-entry
  # #strip is right for prose points, but for a code block it deletes the
  # first line's leading indentation. nil/blank is still "absent" either way.
  def self.improved_code_text(value)
    case value
    when Array then value.map(&:to_s).join("\n")
    else            value.to_s
    end.then { |text| text.blank? ? nil : text }
  end

  def submitted? = submitted_at.present?
  def reviewed?  = ai_review.present?

  def fully_reviewed?
    section_keys.all? { |key| section_reviewed?(key) }
  end

  def section_reviewed?(section)
    ai_review&.dig(section.to_s).is_a?(Hash)
  end

  # History orders `date: :desc`, so the number of strictly-newer submitted
  # sessions is this response's zero-based position in that ordering.
  def history_page
    newer = user.daily_responses.submitted.where("date > ?", date).count
    (newer / HISTORY_PAGE_SIZE) + 1
  end

  def self_rating_for(section) = section_ratings[section.to_s]
  def self_rating_favorable?(section)  = SELF_RATINGS[0, 2].include?(self_rating_for(section)) # too_easy / right_level
  def self_rating_unfavorable?(section) = self_rating_for(section) == "too_hard"
  def self_rating_label(section)       = SELF_RATING_LABELS[self_rating_for(section)]

  def ai_rating_for(section)        = ai_review&.dig(section.to_s, "rating")
  def ai_rating_favorable?(section)   = AI_RATING_FAVORABLE.include?(ai_rating_for(section))
  def ai_rating_unfavorable?(section) = AI_RATING_UNFAVORABLE.include?(ai_rating_for(section))

  # Answer keys with substantive content. The threshold is a heuristic, but it
  # is THE heuristic — the dashboard progress bar, the teaching-hint lock, and
  # the generation prompt all derive from #answered? rather than re-deriving a
  # length check, so there is one definition of "answered" to change.
  #
  # Length is measured against the answer minus the day's scaffold labels (see
  # ExerciseSection.substantive_answer), so a scaffolded section isn't counted
  # as answered for text the user didn't write.
  ANSWER_MIN_LENGTH = 10

  def self.substantive_answer(section, value, section_data = nil)
    kind = ExerciseSection.find(section)
    kind ? kind.substantive_answer(value, section_data) : value.to_s.strip
  end

  def self.answered?(section, value, section_data = nil)
    substantive_answer(section, value, section_data).length > ANSWER_MIN_LENGTH
  end

  # Scaffold labels the user never typed into aren't an answer, so they are not
  # stored as one. Normalizing on write (rather than at each of the several
  # read sites that render or send `answers[section]` verbatim) keeps the AI
  # review prompt, the history display, and recent_performance seeing exactly
  # what they saw before scaffolds existed: a blank answer, or the user's own
  # words. A blanked section simply re-renders its scaffold on the next load.
  def self.normalize_answers(answers, exercise)
    answers.to_h.transform_values(&:to_s).each_with_object({}) do |(section, value), normalized|
      section_data = exercise&.problem_set&.dig(section.to_s)
      normalized[section] = substantive_answer(section, value, section_data).empty? ? "" : value
    end
  end

  def section_data(section)
    daily_exercise&.problem_set&.dig(section.to_s)
  end

  def answered?(section)
    self.class.answered?(section, answers[section.to_s], section_data(section))
  end

  # The sections this response is measured against — the exercise's own, never
  # `answers.keys`. A row can hold an answer for a section its exercise no
  # longer presents (a regenerated day whose third changed), and counting it
  # would report more answered sections than exist and push #completeness past
  # 100%.
  def section_keys
    daily_exercise&.active_section_keys || []
  end

  def answered_sections
    section_keys.select { |section| answered?(section) }
  end

  # Zero-guarded: a payload whose every section key holds a non-Hash presents no
  # answerable sections, and dividing by it yields NaN, which #round raises on.
  def completeness
    total = section_keys.size
    return 0 if total.zero?

    (answered_sections.size / total.to_f * 100).round
  end

  # improved_code is revealed only from a concept's SECOND exposure onward — the
  # first time a concept appears, the corrected answer stays hidden (mirrors the
  # attempt-gated teaching_note). Ungated for blank/"other" (no concept to track).
  # Whether a section kind carries improved_code at all is the kind's own
  # property (see ExerciseSection) — the architecture section never does, and
  # that exclusion lives there rather than in each render template, so both
  # templates stay in sync automatically.
  def improved_code_visible?(section)
    kind = ExerciseSection.find(section)
    return false if kind && !kind.improved_code?

    concept = concept_tags[section.to_s]
    return true if concept.blank? || concept == "other"
    # Resolved the same way User#concept_exposure_index builds its keys. Reading
    # the day's language directly was correct until the fourth slot gave
    # plan_review a bucket of its own, at which point the two sides of this
    # lookup silently stopped agreeing and plan_review's revised plan — the one
    # kind that both carries improved_code and buckets independently — could
    # never become visible.
    bucket = ConceptBucket.for(section, daily_exercise.language)
    user.concept_exposure_count(concept, bucket, on_or_before: date) >= 2
  end
end
