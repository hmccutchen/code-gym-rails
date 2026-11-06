class ConceptMastery::DailyEvidence
  Contribution = Data.define(:concept, :bucket, :work_on, :sections, :pending_sections)

  def self.for(response, accepted_sections:, legacy_sections:)
    new(response, accepted_sections, legacy_sections).contributions
  end

  def initialize(response, accepted, legacy)
    @response = response
    @accepted = accepted - legacy
    @legacy = legacy
  end

  def contributions
    candidates.group_by { |section, concept| [ concept, bucket_for(section) ] }.filter_map do |(concept, bucket), pairs|
      keys = pairs.map(&:first)
      assessed = keys & @accepted & @response.assessed_sections
      next if assessed.empty?

      Contribution.new(concept: concept, bucket: bucket, work_on: @response.date.iso8601,
        sections: assessed.index_with { |key| { "rating" => @response.ai_rating_for(key), "self_rating" => @response.self_rating_for(key) } },
        pending_sections: keys - stored_keys - @legacy)
    end
  end

  private

  def candidates
    return {} unless @response.submitted? && @response.concept_tags.is_a?(Hash)

    @response.concept_tags.slice(*@response.answered_sections).select do |section, concept|
      @response.mastery_evidence?(section) && ConceptBucket.vocabulary_for(bucket_for(section)).include?(concept) && concept != "other"
    end
  end

  def bucket_for(section) = ConceptBucket.for(section, @response.daily_exercise.language)
  def stored_keys = @response.ai_review.is_a?(Hash) ? @response.ai_review.keys : []
end
