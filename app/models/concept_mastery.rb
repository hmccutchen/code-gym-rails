class ConceptMastery < ApplicationRecord
  belongs_to :user

  enum :tier, { standard: 0, reduced: 1, paused: 2 }, prefix: true

  # The one place selection says "rows of this bucket that its vocabulary still
  # holds." Both halves belong together: a row survives a concept being renamed
  # or dropped from a vocabulary, and such a row can never resolve — the
  # generator is only offered vocabulary concepts, ingest normalizes anything
  # else to "other", and .record_review! skips "other" — so it would stay due
  # and keep claiming a slot forever (issue #97).
  #
  # Filtering on `language:` alone is exactly that bug. Every selection query
  # goes through here so a new one cannot reintroduce it by omission.
  scope :in_bucket, ->(bucket) { where(language: bucket, concept: ConceptBucket.vocabulary_for(bucket)) }

  AI_RATING_RANK = { "beginner" => 0, "developing" => 1, "solid" => 2, "strong" => 3 }.freeze

  # Once a concept is mastered it would otherwise never resurface. These schedule
  # a re-check at expanding intervals: 7 days ≈ 5 weekday sessions (long enough to
  # forget, short enough to catch decay), doubling per successful check, capped at
  # 60 days because each vocabulary is only 13-16 concepts — past two months
  # ordinary rotation resurfaces the concept anyway.
  RETENTION_INITIAL_INTERVAL_DAYS = 7
  RETENTION_GROWTH_FACTOR         = 2
  RETENTION_MAX_INTERVAL_DAYS     = 60
  # How far past its own due date a check must fall before it's "meaningfully
  # overdue" enough to bump a reinforcement slot: 1 means overdue by 100% of
  # the concept's own current retention_interval_days (a 7-day check crosses
  # at 14 days past due, a 28-day check at 56). Sits alongside
  # RETENTION_GROWTH_FACTOR as an equally tunable knob on the same schedule.
  RETENTION_OVERDUE_THRESHOLD_MULTIPLIER = 1

  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: [ :user_id, :language ] }

  # Called inside ResponsesController#review, in one transaction per successful
  # batch of sections (a review action may fire this more than once across
  # retries, each time with a disjoint `sections:` — a section can only ever be
  # evaluated once, since it's removed from "missing" the moment it succeeds).
  # `apply_session_countdown:` gates Step A (the once-per-day paused-cooldown
  # decrement) so a later partial-retry within the same day's review never
  # re-runs it — the controller passes true only on the first successful batch
  # for a given response.
  def self.record_review!(response, sections:, apply_session_countdown:)
    user = response.user

    if apply_session_countdown
      user.concept_masteries.tier_paused.each do |cm|
        remaining = cm.cooldown_remaining - 1
        if remaining <= 0
          cm.update!(tier: :reduced, streak: 0, cooldown_remaining: 0)
        else
          cm.update!(cooldown_remaining: remaining)
        end
      end
    end

    sections_by_concept = Hash.new { |h, k| h[k] = [] }
    response.concept_tags.slice(*sections).each do |section, concept|
      next if concept.blank? || concept == "other"
      sections_by_concept[concept] << section
    end

    sections_by_concept.each do |concept, secs|
      bucket = ConceptBucket.for(secs, response.daily_exercise.language)
      evaluate_concept!(user, concept, bucket, response, secs)
    end
  end

  # Least-favorable-section-wins: the day's representative AI rating is the
  # lowest-ranked across the concept's sections; self is favorable only if
  # every such section is favorable. An unreviewed section means no AI signal
  # for the day, so we skip (no mastery/streak movement without an AI rating).
  def self.evaluate_concept!(user, concept, bucket, response, sections)
    ai_ratings = sections.map { |s| response.ai_rating_for(s) }
    return if ai_ratings.any?(&:nil?)

    rep_ai   = ai_ratings.min_by { |r| AI_RATING_RANK.fetch(r, -1) }
    self_fav = sections.all? { |s| response.self_rating_favorable?(s) }

    cm = user.concept_masteries.find_or_initialize_by(concept: concept, language: bucket)
    return if cm.tier_paused? # paused concepts only count down (Step A)

    prev      = cm.last_rating
    mastered  = self_fav && DailyResponse::AI_RATING_FAVORABLE.include?(rep_ai)
    improving = prev.present? && AI_RATING_RANK.fetch(rep_ai, -1) > AI_RATING_RANK.fetch(prev, -1)

    if mastered
      cm.assign_attributes(tier: :standard, streak: 0, cooldown_remaining: 0)
      cm.assign_attributes(**retention_schedule_for(cm, response.date))
    elsif improving || prev.blank?
      cm.streak = 0
    else # stagnant: same-or-worse than last time
      cm.streak += 1
      if cm.tier_standard? && cm.streak >= 3
        cm.assign_attributes(tier: :reduced, streak: 0)
      elsif cm.tier_reduced? && cm.streak >= 2
        cm.assign_attributes(tier: :paused, streak: 0, cooldown_remaining: 2)
      end
    end

    unless mastered
      # A failed check drops the schedule entirely; the concept re-enters normal
      # reinforcement through concepts_needing_reinforcement's existing rules, so
      # there is no parallel "retry the check" path to maintain. mastered_at stays
      # as a historical record that it was once mastered — see retention_schedule_for,
      # which only ever sets it the first time.
      cm.assign_attributes(next_retention_check_on: nil, retention_interval_days: nil)
    end

    cm.last_rating = rep_ai
    cm.save!
  end

  # The interval only grows when the scheduled check was actually DUE. Without that
  # guard, mastering the same concept three days running would inflate 7 → 14 → 28
  # with no real spacing behind it; here the date is simply re-anchored instead.
  #
  # `on_date` (response.date, the day the submitted work covers) decides whether
  # the check was due — that's a question about the work being reviewed, and a
  # late review shouldn't change the answer. But the NEXT check has to count
  # forward from today (the day we're actually scheduling it), not from
  # response.date — otherwise reviewing a 10-day-old submission schedules a
  # check that's already days in the past and immediately due.
  def self.retention_schedule_for(cm, on_date)
    due = cm.next_retention_check_on.present? && cm.next_retention_check_on <= on_date

    interval =
      if cm.retention_interval_days.blank?
        RETENTION_INITIAL_INTERVAL_DAYS
      elsif due
        [ cm.retention_interval_days * RETENTION_GROWTH_FACTOR, RETENTION_MAX_INTERVAL_DAYS ].min
      else
        cm.retention_interval_days
      end

    {
      # Set only on first mastery — mastered_at is a historical "when was this
      # concept first mastered" record, not a "most recently" timestamp, so a
      # later successful retention check must not overwrite it.
      mastered_at:             cm.mastered_at || Time.current,
      retention_interval_days: interval,
      next_retention_check_on: Date.current + interval
    }
  end
  private_class_method :retention_schedule_for
end
