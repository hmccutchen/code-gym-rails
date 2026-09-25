# Which rung a user currently holds for each concept, read from stored
# evidence: the most recent answered, reviewed, un-eased section pitched at
# each rung, held when both ratings were favourable — the co-favourable rule
# ConceptMastery.record_review! applies, on the same terms: a concept tagged
# on several sections of one day is judged by its least favourable section,
# and a review that stored no rating is no signal rather than a bad one. The
# concept's standing is the highest held rung, which covers the rungs below
# it; a later poor attempt at a rung releases it, so this describes now.
#
# Pure over the response objects it is given, newest first: nothing here
# queries, and nothing compares a date to today, so time alone changes no
# answer. Sections from before rungs were stamped carry no rung and are not
# attempts; neither is an eased one, since the problem was easier than the
# rung says.
class RungLedger
  RESPONSE_COLUMNS = %i[id daily_exercise_id date answers concept_tags section_ratings ai_review].freeze

  # Only the columns the verdicts read; the exercise rows come whole, since
  # their problem_set is where the rungs live.
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

  private

  # First sighting wins: responses arrive newest first, so the verdict kept
  # for a (concept, bucket, rung) is the most recent day that attempted it.
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
