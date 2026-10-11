# The browser's copy is CodeGymAnswerRules.sectionStatus; spec/system/answer_rules_parity_spec.rb holds them together.
module SectionStatusHelper
  def section_status(response, key)
    return "" unless response.answered?(key)

    label = response.self_rating_label(key)
    label ? "✓ #{label}" : t("responses.section_status.in_progress")
  end
end
