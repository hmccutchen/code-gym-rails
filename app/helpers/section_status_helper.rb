# Mirrored by the dashboard script's refreshStatus against the live form; change both together.
module SectionStatusHelper
  def section_status(response, key)
    return "" unless response.answered?(key)

    label = response.self_rating_label(key)
    label ? "✓ #{label}" : t("responses.section_status.in_progress")
  end
end
