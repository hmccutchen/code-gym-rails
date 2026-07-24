class ConceptMastery < ApplicationRecord
  belongs_to :user

  enum :tier, { standard: 0, reduced: 1, paused: 2 }, prefix: true

  AI_RATING_RANK = { "beginner" => 0, "developing" => 1, "solid" => 2, "strong" => 3 }.freeze

  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: [ :user_id, :language ] }

  # Called inside ResponsesController#review, in the same transaction as the
  # ai_review save. Counts one "session" (a real submit+review day): first
  # decrements every paused concept's cooldown, then evaluates each distinct
  # concept in this response for improving/stagnant/mastered transitions.
  def self.record_review!(response)
    user = response.user

    # Step A — session countdown for paused concepts.
    user.concept_masteries.tier_paused.each do |cm|
      remaining = cm.cooldown_remaining - 1
      if remaining <= 0
        cm.update!(tier: :reduced, streak: 0, cooldown_remaining: 0)
      else
        cm.update!(cooldown_remaining: remaining)
      end
    end

    # Step B — evaluate each distinct concept (one evaluation per concept/day).
    sections_by_concept = Hash.new { |h, k| h[k] = [] }
    response.concept_tags.each do |section, concept|
      next if concept.blank? || concept == "other"
      sections_by_concept[concept] << section
    end

    sections_by_concept.each do |concept, sections|
      bucket = sections.include?("architecture") ? "architecture" : response.daily_exercise.language
      evaluate_concept!(user, concept, bucket, response, sections)
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

    cm.last_rating = rep_ai
    cm.save!
  end
end
