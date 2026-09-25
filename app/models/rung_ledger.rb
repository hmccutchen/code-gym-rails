# Which rung a user currently holds for each concept, read from stored
# evidence: the most recent answered, reviewed, un-eased section pitched at
# each rung, held when both ratings were favourable — the co-favourable rule
# ConceptMastery.record_review! applies. The concept's standing is the
# highest held rung, which covers the rungs below it; a later poor attempt at
# a rung releases it, so this describes now.
#
# Pure over the response objects it is given, newest first: nothing here
# queries, and nothing compares a date to today, so time alone changes no
# answer. Sections from before rungs were stamped carry no rung and are not
# attempts; neither is an eased one, since the problem was easier than the
# rung says.
class RungLedger
  def self.for(user)
    new(user.daily_responses.where.not(submitted_at: nil).includes(:daily_exercise).order(date: :desc))
  end

  def initialize(responses)
    @verdicts = {}
    responses.each { |response| record(response) }
  end

  # The highest rung held for the concept in this bucket, or nil.
  def held(concept, bucket)
    KindDifficulty::LEVELS.reverse.find { |rung| @verdicts[[ concept, bucket, rung ]] }
  end

  private

  # First sighting wins: responses arrive newest first, so the verdict kept
  # for a (concept, bucket, rung) is the most recent attempt at it.
  def record(response)
    exercise = response.daily_exercise
    response.answered_concept_tags.each do |section, concept|
      next if concept.blank? || concept == "other"

      data = exercise.problem_set[section]
      next unless data.is_a?(Hash) && data["pitched_at"].present? && !data["eased"]
      next unless response.section_reviewed?(section)

      key = [ concept, ConceptBucket.for(section, exercise.language), data["pitched_at"] ]
      next if @verdicts.key?(key)

      @verdicts[key] = response.self_rating_favorable?(section) && response.ai_rating_favorable?(section)
    end
  end
end
