module AdaptationHistory
  def self.recent(user, limit:, before: nil)
    return [] unless limit.positive?

    responses = user.daily_responses.submitted.preload(:daily_exercise)
    responses = responses.where("daily_responses.date < ?", before) if before
    retained = []
    responses.find_each(cursor: %i[date id], order: %i[desc desc]) do |response|
      next if response.assessed_sections.empty?

      projection = yield response
      retained << projection if projection.present?
      break if retained.size >= limit
    end
    retained
  end
end
