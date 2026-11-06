class ConceptMastery::DailyEvidence
  Contribution = Data.define(:concept, :bucket, :work_on, :sections, :pending_sections)

  def self.for(response, accepted_sections:, legacy_sections:, policy: 1)
    new(response, accepted_sections, legacy_sections, policy).contributions
  end

  def initialize(response, accepted, legacy, policy)
    @response = response
    @accepted = accepted - legacy
    @legacy = legacy
    @policy = policy
  end

  def contributions
    candidates.group_by { |_section, tag| tag }.filter_map do |(bucket, concept), pairs|
      keys = pairs.map(&:first)
      assessed = keys & @accepted & @response.assessed_sections
      next if assessed.empty?

      Contribution.new(concept: concept, bucket: bucket, work_on: @response.date.iso8601,
        sections: assessed.index_with { |key| evidence(key) },
        pending_sections: keys - stored_keys - @legacy)
    end
  end

  private

  def evidence(key)
    value = { "rating" => @response.ai_rating_for(key), "self_rating" => @response.self_rating_for(key) }
    value["eased"] = @response.daily_exercise.problem_set.dig(key, "eased") == true if @policy == 2
    value
  end

  def candidates
    return [] unless @response.submitted? && @response.concept_tags.is_a?(Hash)

    @response.concept_tags.slice(*@response.answered_sections).filter_map do |section, _concept|
      tag = @response.mastery_tag(section)
      [ section, tag ] if tag
    end
  end

  def stored_keys = @response.ai_review.is_a?(Hash) ? @response.ai_review.keys : []
end
