module ReviewHelper
  ReviewBadge = Data.define(:text, :graded) do
    def graded? = graded
  end

  ShortVersion = Data.define(:reference, :bucket, :show_pitfalls, :learn_link)

  def review_takeaway(response, section)
    ReviewTakeaway.call(response, section) if ReviewTakeawayPresentation.enabled?
  end

  def review_short_version(response, section)
    short_version = short_version_for(response)
    return unless short_version.offered?(section)

    concept, bucket = short_version.key(section)
    reference = concept_reference_for(concept, bucket)
    return unless reference

    ShortVersion.new(reference: reference, bucket: bucket, show_pitfalls: short_version.pitfalls?(section),
                     learn_link: ConceptBucket.slice_for(response.user.language).include?(bucket))
  end

  def review_provider_label(response)
    AiProvider.label(response.review_provider_key)
  end

  def review_badge(response, section)
    if response.ungradable_review?(section)
      ReviewBadge.new(text: t("review.ungradable_label"), graded: false)
    elsif (rating = response.ai_rating_for(section)).present?
      ReviewBadge.new(text: rating, graded: true)
    elsif !response.answered?(section)
      ReviewBadge.new(text: t("review.skipped_label"), graded: false)
    end
  end

  def review_section_name(response, section)
    presentation = ExerciseSection.find(section)&.presentation_key(response.section_data(section))
    presentation ? t("sections.#{presentation}.name") : section.humanize
  end

  def review_qualitative_feedback(response, section, feedback)
    kind = ExerciseSection.find(section)
    data = response.section_data(section)
    variant = kind&.grading_variant(data)
    return [] unless variant

    presentation = kind.presentation_key(data)
    variant.feedback_fields.filter_map do |field|
      text = feedback[field]
      [ t("sections.#{presentation}.feedback.#{field}"), text ] if text.is_a?(String) && text.present?
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
