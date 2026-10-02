# The line a folded section shows beside its label, so folding reduces
# scrolling without losing where things stand. Stated once here and mirrored
# by the dashboard script's refreshStatus against the live form.
module SectionStatusHelper
  def section_status(response, key)
    return "" unless response.answered?(key)

    label = response.self_rating_label(key)
    label ? "✓ #{label}" : t("responses.section_status.in_progress")
  end
end
