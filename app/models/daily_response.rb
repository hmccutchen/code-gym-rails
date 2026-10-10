class DailyResponse < ApplicationRecord
  belongs_to :user, inverse_of: :daily_responses
  belongs_to :daily_exercise
  has_many :review_follow_ups, dependent: :destroy

  SELF_RATINGS = %w[too_easy right_level too_hard].freeze
  SELF_RATING_FAVORABLE = SELF_RATINGS[0, 2].freeze
  SELF_RATING_UNFAVORABLE = (SELF_RATINGS - SELF_RATING_FAVORABLE).freeze

  AI_RATING_FAVORABLE   = %w[solid strong].freeze
  AI_RATING_UNFAVORABLE = %w[beginner developing].freeze

  # Describes the problem, not the person; a spec holds this disjoint from the AI grade vocabulary.
  DIFFICULTY_LEVELS = %w[straightforward moderate demanding].freeze

  # Bounds provider prose rendered into the page.
  MAX_DIFFICULTY_REASON_LENGTH = 200

  # Enforced server-side too: the view hiding the button does not hold against a crafted request.
  MAX_ALTERNATES_PER_SECTION = 2

  MAX_FOLLOW_UPS_PER_SECTION = 3

  # How many History entries render per page.
  HISTORY_PAGE_SIZE = 10

  validates :date, uniqueness: { scope: :user_id }

  scope :submitted, -> { where.not(submitted_at: nil) }

  # Shared by shared/_ai_review and ReviewMailer; next_step is deliberately one thing to study, so not a list.
  AI_REVIEW_FIELDS = {
    "correct"          => { list: true  },
    "missed"           => { list: true  },
    "better_questions" => { list: true  },
    "next_step"        => { list: false }
  }.freeze

  # A prompt passes locale: :en so provider text never follows a request's locale.
  def self.ai_review_label(field, locale: I18n.locale)
    I18n.t("review.fields.#{field}", locale: locale)
  end

  # Read at render time, so a request's locale chooses the wording.
  def self.self_rating_labels
    SELF_RATINGS.index_with { |rating| I18n.t("self_ratings.#{rating}") }
  end

  # Older reviews stored a single string. A class method because mailer views don't include helpers.
  def self.review_points(value)
    case value
    when Array then value.map { |v| v.to_s.strip }.reject(&:blank?)
    else            [ value.to_s.strip ].reject(&:blank?)
    end
  end

  # Entries are not stripped: that would delete the code block's first-line indentation.
  def self.improved_code_text(value)
    case value
    when Array then value.map(&:to_s).join("\n")
    else            value.to_s
    end.then { |text| text.blank? ? nil : text }
  end

  # Must outlast the longest review chain (ai_service_spec checks); a literal, since deriving it couples load order.
  REVIEW_CLAIM_STALE_AFTER = 12.minutes

  def submitted? = submitted_at.present?
  def reviewed?  = ai_review.present?

  # Switching providers records the outgoing one first, so a review with none came from the current provider.
  def review_provider_label = AiProvider.label(review_provider.presence || user.provider)

  # Anything that would destroy this row must ask: a destroy mid-flight discards a review already paid for.
  def reviewing?
    reviewing_since.present? && reviewing_since > REVIEW_CLAIM_STALE_AFTER.ago
  end

  def fully_reviewed?
    section_keys.all? { |key| section_reviewed?(key) }
  end

  def section_reviewed?(section)
    ai_review&.dig(section.to_s).is_a?(Hash)
  end

  def pseudocode_round(section)
    pseudocode_rounds[section.to_s] || {}
  end

  # Keyed on the timestamp: a critique that found no gaps stores [], which is not present?.
  def critiqued?(section)
    pseudocode_round(section)["critiqued_at"].present?
  end

  def translated?(section)
    pseudocode_round(section)["translated_at"].present?
  end

  # Nils are dropped, which lets a caller clear a claim in the same merge that records its result.
  def merge_pseudocode_round!(section, attrs)
    rounds = pseudocode_rounds.deep_dup
    rounds[section.to_s] = (rounds[section.to_s] || {}).merge(attrs).compact
    update!(pseudocode_rounds: rounds)
  end

  # Under the row lock: a critique round can be in flight, and this read-modify-write would overwrite it.
  def record_translation!(section, code:, pseudocode:)
    with_lock do
      merge_pseudocode_round!(section,
        "generated_code"  => code,
        "translated_from" => pseudocode,
        "translated_at"   => Time.current.iso8601)
    end
  end

  # Reuses REVIEW_CLAIM_STALE_AFTER on purpose: both ask whether a paid call may still be running.
  def pseudocode_claimed?(section, phase)
    claimed_at = pseudocode_round(section)["#{phase}_claimed_at"]
    return false if claimed_at.blank?

    Time.zone.parse(claimed_at) > REVIEW_CLAIM_STALE_AFTER.ago
  end

  def self_rating_for(section) = section_ratings[section.to_s]
  def self_rating_favorable?(section)  = SELF_RATING_FAVORABLE.include?(self_rating_for(section))
  def self_rating_unfavorable?(section) = SELF_RATING_UNFAVORABLE.include?(self_rating_for(section))
  def self_rating_label(section)       = self.class.self_rating_labels[self_rating_for(section)]

  # Applied on write and again on read, since ai_review is schemaless jsonb.
  def self.usable_difficulty(assessment)
    return unless assessment.is_a?(Hash) && DIFFICULTY_LEVELS.include?(assessment["level"])

    reason = assessment["reason"]
    { "level"  => assessment["level"],
      "reason" => (reason.is_a?(String) ? reason.strip : "").truncate(MAX_DIFFICULTY_REASON_LENGTH) }
  end

  def difficulty_for(section)
    self.class.usable_difficulty(ai_review&.dig(section.to_s, "difficulty"))
  end

  def ai_rating_for(section)        = ai_review&.dig(section.to_s, "rating")
  def ai_rating_favorable?(section)   = AI_RATING_FAVORABLE.include?(ai_rating_for(section))
  def ai_rating_unfavorable?(section) = AI_RATING_UNFAVORABLE.include?(ai_rating_for(section))

  # Measured after removing the day's scaffold labels (ExerciseSection.substantive_answer).
  ANSWER_MIN_LENGTH = 10

  def self.substantive_answer(section, value, section_data = nil)
    kind = ExerciseSection.find(section)
    kind ? kind.substantive_answer(value, section_data) : value.to_s.strip
  end

  def self.answered?(section, value, section_data = nil)
    (ExerciseSection.find(section) || ExerciseSection).answered?(value, section_data)
  end

  # Scaffold-only drafts store as blank so a reload offers the scaffold again.
  def self.normalize_answers(answers, exercise)
    answers.to_h.each_with_object({}) do |(section, value), normalized|
      cleaned = UserText.clean(value, limit: UserText::MAX_ANSWER_LENGTH)
      section_data = exercise&.problem_set&.dig(section.to_s)
      kind         = ExerciseSection.find(section) || ExerciseSection
      decoded      = kind.decode_answer(cleaned, exercise: exercise, key: section.to_s, section_data: section_data)
      next if decoded.nil?

      normalized[section] = substantive_answer(section, decoded, section_data).empty? ? "" : decoded
    end
  end

  def section_data(section)
    daily_exercise&.problem_set&.dig(section.to_s)
  end

  def answered?(section)
    self.class.answered?(section, answers[section.to_s], section_data(section))
  end

  def answer_for(section)
    (ExerciseSection.find(section) || ExerciseSection).answer_for(answers[section.to_s], section_data(section))
  end

  # Never answers.keys: a regenerated day can leave answers for sections it no longer shows.
  def section_keys
    daily_exercise&.active_section_keys || []
  end

  def answered_sections
    section_keys.select { |section| answered?(section) }
  end

  # A grade on a skipped answer measures nothing; exposure readers use #concept_tags instead.
  def answered_concept_tags
    concept_tags.slice(*answered_sections)
  end

  # A day with nothing answered owes no rating but is not ready. The dashboard script restates these checks.
  def submit_blocker
    answered = answered_sections
    if answered.empty?
      :unanswered
    elsif (answered - section_ratings.keys).any?
      :unrated
    end
  end

  def submittable?
    submit_blocker.nil?
  end

  # Zero-guarded: a payload with no Hash sections would divide to NaN, which #round raises on.
  def completeness
    total = section_keys.size
    return 0 if total.zero?

    (answered_sections.size / total.to_f * 100).round
  end

  # Revealed only from a concept's second exposure onward; ungated for blank or "other".
  def improved_code_visible?(section)
    kind = ExerciseSection.find(section)
    return false if kind && !kind.improved_code?

    concept = concept_tags[section.to_s]
    return true if concept.blank? || concept == "other"
    # Must match User#concept_exposure_index's keys, or plan_review's revised plan never becomes visible.
    bucket = ConceptBucket.for(section, daily_exercise.language)
    user.concept_exposure_count(concept, bucket, on_or_before: date) >= 2
  end
end
