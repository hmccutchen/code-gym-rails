module AdaptationHistory
  BATCH_SIZE = 100

  def self.recent(user, limit:, before: nil, require_rubric: false)
    return [] unless limit.positive?

    responses = user.daily_responses.submitted.reviewed.preload(:daily_exercise)
    responses = responses.where("daily_responses.date < ?", before) if before
    responses = ReviewedSectionResults.with_current_rubric(responses) if require_rubric
    retained = []
    responses.find_each(cursor: %i[date id], order: %i[desc desc], batch_size: BATCH_SIZE) do |response|
      next if response.assessed_sections.empty?

      projection = yield response
      retained << projection if projection.present?
      break if retained.size >= limit
    end
    retained
  end
end
