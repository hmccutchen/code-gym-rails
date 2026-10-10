# Pure over responses given newest first, and never compares to today, so time alone changes no answer.
class RungLedger
  RESPONSE_COLUMNS = %i[id daily_exercise_id date answers concept_tags section_ratings ai_review].freeze

  # Exercises load whole because their problem_set holds the rungs.
  def self.for(user)
    new(user.daily_responses.submitted.select(*RESPONSE_COLUMNS).preload(:daily_exercise).order(date: :desc))
  end

  def initialize(responses)
    @verdicts = {}
    responses.each { |response| record(response) }
  end

  # The highest rung held for the concept in this bucket, or nil.
  def held(concept, bucket)
    KindDifficulty::LEVELS.reverse.find { |rung| @verdicts[[ concept, bucket, rung ]] }
  end

  # Every verdict above the held rung failed to hold, or that rung would be the held one.
  def developing_toward(concept, bucket)
    held_rung = held(concept, bucket)
    above = held_rung ? KindDifficulty::LEVELS.drop(KindDifficulty::LEVELS.index(held_rung) + 1) : KindDifficulty::LEVELS
    above.first if above.any? { |rung| @verdicts.key?([ concept, bucket, rung ]) }
  end

  private

  # First sighting wins, because responses arrive newest first.
  def record(response)
    attempts(response).each do |key, sections|
      next if @verdicts.key?(key)

      @verdicts[key] = sections.all? { |section| response.self_rating_favorable?(section) && response.ai_rating_favorable?(section) }
    end
  end

  # The day's sections grouped under the (concept, bucket, rung) each attempted.
  def attempts(response)
    exercise = response.daily_exercise
    response.answered_concept_tags.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(section, concept), grouped|
      next if concept.blank? || concept == "other"
      next if response.ai_rating_for(section).nil?

      data = exercise.problem_set[section]
      next unless data.is_a?(Hash) && data["pitched_at"].present? && !data["eased"]

      grouped[[ concept, ConceptBucket.for(section, exercise.language), data["pitched_at"] ]] << section
    end
  end
end
