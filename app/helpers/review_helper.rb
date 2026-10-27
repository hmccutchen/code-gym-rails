module ReviewHelper
  ReviewBadge = Data.define(:text, :graded) do
    def graded? = graded
  end

  def review_badge(response, section)
    if (rating = response.ai_rating_for(section)).present?
      ReviewBadge.new(text: rating, graded: true)
    elsif !response.answered?(section)
      ReviewBadge.new(text: t("review.skipped_label"), graded: false)
    end
  end

  def review_field_label(response, section, field)
    walkthrough_key = "review.walkthrough_fields.#{field}"
    return t(walkthrough_key) if !response.answered?(section) && I18n.exists?(walkthrough_key)

    DailyResponse.ai_review_label(field)
  end
end
