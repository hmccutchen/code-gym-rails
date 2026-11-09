module AdaptationHistory
  BATCH_SIZE = 100

  def self.recent(user, limit:, before: nil, require_rubric: false)
    return [] unless limit.positive?

    retained = []
    each(user, before: before, require_rubric: require_rubric) do |response|
      projection = yield response
      retained << projection if projection.present?
      break if retained.size >= limit
    end
    retained
  end

  def self.each(user, before: nil, on_or_after: nil, require_rubric: false)
    return enum_for(__method__, user, before: before, on_or_after: on_or_after, require_rubric: require_rubric) unless block_given?

    responses = user.daily_responses.submitted.reviewed.preload(:daily_exercise)
    responses = responses.where("daily_responses.date < ?", before) if before
    responses = responses.where("daily_responses.date >= ?", on_or_after) if on_or_after
    responses = ReviewedSectionResults.with_current_rubric(responses) if require_rubric
    responses.find_each(cursor: %i[date id], order: %i[desc desc], batch_size: BATCH_SIZE) do |response|
      next if response.assessed_sections.empty?

      yield response
    end
  end
end
