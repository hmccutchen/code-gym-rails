# The dashboard shows this text from each save reply too, so this is its only statement.
module SectionStatusHelper
  def section_status(response, key)
    return "" unless response.answered?(key)

    label = self_rating_label(response, key)
    label ? "✓ #{label}" : t("responses.section_status.in_progress")
  end
end
