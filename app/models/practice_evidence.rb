class PracticeEvidence
  GAP_LIMIT = 300

  def self.for(user, before:, kinds: ExerciseSection.keys, initial_ready: false)
    struggle = {}
    required = PracticeSchedule::Turns::INITIAL_REVIEWED_SETS
    reviewed = initial_ready ? required : 0
    history = initial_ready && kinds.empty? ? [] : AdaptationHistory.each(user, before: before)
    history.each do |response|
      reviewed += 1 if reviewed < PracticeSchedule::Turns::INITIAL_REVIEWED_SETS &&
        response.completion_evidence?(sections: response.adaptation_section_keys)
      response.assessed_adaptation_sections.each do |key|
        next if !kinds.include?(key) || struggle.key?(key)

        value = informative(response, key)
        struggle[key] = value unless value.nil?
      end
      break if reviewed >= required && (kinds - struggle.keys).empty?
    end
    { initial_reviewed_sets: reviewed, struggle: struggle, pending: pending_for(user) }
  end

  def self.pending_for(user)
    requests = user.concept_masteries.in_buckets(ConceptBucket.slice_for(user.language))
      .where.not(tier: :paused).where.not(practice_requests: {}).flat_map do |row|
        ConceptMastery::Reconciliation.validate_requests!(row.practice_requests).map do |kind, request|
          { kind: kind, concept: row.concept, bucket: row.language, mode: request.fetch("mode"),
            source_response_id: request.fetch("source_response_id"), requested_at: request.fetch("requested_at") }
        end
      end
    sources = user.daily_responses.where(id: requests.map { |request| request[:source_response_id] }).preload(:daily_exercise).index_by(&:id)
    requests.map { |request| request.merge(gap: gap_for(sources[request[:source_response_id]], request)) }
  end

  def self.informative(response, key)
    return true if !response.ai_rating_favorable?(key) || response.self_rating_for(key) == "too_hard"
    false if response.self_rating_favorable?(key) && response.daily_exercise.problem_set.dig(key, "eased") != true
  end
  private_class_method :informative

  def self.gap_for(response, request)
    key = request.fetch(:kind)
    return unless response && response.assessed_adaptation_sections.include?(key) &&
      response.mastery_tag(key) == request.values_at(:bucket, :concept)

    missed = ReviewProseVerdict.as_graded(response.ai_review[key])&.dig("missed")
    return unless missed.is_a?(String) || (missed.is_a?(Array) && missed.all?(String))

    DailyResponse.review_points(missed).find(&:present?)&.first(GAP_LIMIT)
  end
  private_class_method :gap_for
end
