module SelfRatingHelper
  def self_rating_labels
    DailyResponse::SELF_RATINGS.index_with { |rating| t("self_ratings.#{rating}") }
  end

  def self_rating_label(response, section)
    self_rating_labels[response.self_rating_for(section)]
  end
end
