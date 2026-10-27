module ReviewHelper
  ReviewBadge = Data.define(:text, :graded) do
    def graded? = graded
  end

  ShortVersion = Data.define(:reference, :bucket, :show_pitfalls)

  def review_short_version(response, section)
    short_version = short_version_for(response)
    return unless short_version.offered?(section)

    concept, bucket = short_version.key(section)
    reference = concept_reference_for(concept, bucket)
    ShortVersion.new(reference: reference, bucket: bucket, show_pitfalls: short_version.pitfalls?(section)) if reference
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

  private

  def short_version_for(response)
    @short_versions ||= {}.compare_by_identity
    @short_versions[response] ||= ReviewShortVersion.new(response, exposures: response.user.concept_exposures)
  end
end
