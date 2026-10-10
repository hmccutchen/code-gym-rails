# Design notes: docs/code-notes/app/models/concept_mastery.md
class ConceptMastery < ApplicationRecord
  belongs_to :user

  enum :tier, { standard: 0, reduced: 1, paused: 2 }, prefix: true

  # Every selection query goes through here: filtering on `language:` alone keeps dead-concept rows due (#97).
  scope :in_bucket, ->(bucket) { where(language: bucket, concept: ConceptBucket.vocabulary_for(bucket)) }
  scope :in_buckets, ->(buckets) { buckets.map { |bucket| in_bucket(bucket) }.reduce(none, :or) }
  scope :drilling, -> { where.not(drilled_at: nil) }
  scope :due_for_retention_check, -> { where.not(next_retention_check_on: nil).where(next_retention_check_on: ..Date.current) }

  AI_RATING_RANK = { "beginner" => 0, "developing" => 1, "solid" => 2, "strong" => 3 }.freeze

  # Capped at 60 days, where a re-check stops measuring retention; never derive this from vocabulary size (#98).
  RETENTION_INITIAL_INTERVAL_DAYS = 7
  RETENTION_GROWTH_FACTOR         = 2
  RETENTION_MAX_INTERVAL_DAYS     = 60
  RETENTION_OVERDUE_THRESHOLD_MULTIPLIER = 1

  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: [ :user_id, :language ] }

  # Pass apply_session_countdown: true only on a response's first successful batch, so retries never re-run Step A.
  def self.record_review!(response, sections:, apply_session_countdown:)
    user = response.user

    count_down_paused_concepts!(user) if apply_session_countdown
    defer_skipped_checks!(response, sections)

    sections_by_concept = Hash.new { |h, k| h[k] = [] }
    response.answered_concept_tags.slice(*sections).each do |section, concept|
      next if concept.blank? || concept == "other"
      sections_by_concept[concept] << section
    end

    sections_by_concept.each do |concept, secs|
      bucket = ConceptBucket.for(secs, response.daily_exercise.language)
      evaluate_concept!(user, concept, bucket, response, secs)
    end
  end

  def self.count_down_paused_concepts!(user)
    user.concept_masteries.tier_paused.each do |cm|
      remaining = cm.cooldown_remaining - 1
      if remaining <= 0
        cm.end_pause
        cm.save!
      else
        cm.update!(cooldown_remaining: remaining)
      end
    end
  end
  private_class_method :count_down_paused_concepts!

  def self.defer_skipped_checks!(response, sections)
    return unless response.submitted?

    scopes = skipped_check_scopes(response, sections)
    return if scopes.empty?

    Time.use_zone(response.user.effective_time_zone) do
      transaction do
        scopes.reduce(:or).where(next_retention_check_on: ..response.date)
          .where("retention_interval_days > 0").lock.each do |cm|
          cm.update!(next_retention_check_on: [ Date.current, response.date ].max + cm.retention_interval_days)
        end
      end
    end
  end
  private_class_method :defer_skipped_checks!

  def self.skipped_check_scopes(response, sections)
    answered = response.answered_concept_tags.values
    tags = response.concept_tags.slice(*(sections & response.section_keys))
      .reject { |section, concept| answered.include?(concept) || !response.section_reviewed?(section) }
    tags.group_by { |section, _| ConceptBucket.for(section, response.daily_exercise.language) }
      .map do |bucket, pairs|
        response.user.concept_masteries.in_bucket(bucket).where(concept: pairs.map(&:last))
      end
  end
  private_class_method :skipped_check_scopes

  def self.evaluate_concept!(user, concept, bucket, response, sections)
    ai_ratings = sections.map { |s| response.ai_rating_for(s) }
    return if ai_ratings.any?(&:nil?)

    rep_ai   = ai_ratings.min_by { |r| AI_RATING_RANK.fetch(r, -1) }
    self_fav = sections.all? { |s| response.self_rating_favorable?(s) }

    cm = user.concept_masteries.find_or_initialize_by(concept: concept, language: bucket)
    return if cm.tier_paused?

    prev      = cm.last_rating
    mastered  = self_fav && DailyResponse::AI_RATING_FAVORABLE.include?(rep_ai)
    improving = prev.present? && AI_RATING_RANK.fetch(rep_ai, -1) > AI_RATING_RANK.fetch(prev, -1)

    if mastered
      cm.assign_attributes(tier: :standard, streak: 0, cooldown_remaining: 0)
      cm.clear_drill
      cm.assign_attributes(**retention_schedule_for(cm, response.date))
    elsif improving || prev.blank?
      cm.streak = 0
    else
      cm.streak += 1
      if cm.tier_standard? && cm.streak >= 3
        cm.assign_attributes(tier: :reduced, streak: 0)
      elsif cm.tier_reduced? && cm.streak >= 2
        cm.assign_attributes(tier: :paused, streak: 0, cooldown_remaining: 2)
      end
    end

    unless mastered
      cm.assign_attributes(next_retention_check_on: nil, retention_interval_days: nil)
    end

    cm.last_rating = rep_ai
    cm.save!
  end

  # Grow only when the check was due on the work's date; count the next check forward from today, not that date.
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
      mastered_at:             cm.mastered_at || Time.current,
      retention_interval_days: interval,
      next_retention_check_on: Date.current + interval
    }
  end
  private_class_method :retention_schedule_for

  def end_pause
    assign_attributes(tier: :reduced, streak: 0, cooldown_remaining: 0)
  end

  def clear_drill
    assign_attributes(drilled_at: nil, drill_group: nil)
  end

  def clear_drill!
    clear_drill
    save!
  end
end
