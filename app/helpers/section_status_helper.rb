# The line a folded section shows beside its label, so folding reduces
# scrolling without losing where things stand. Stated once here and mirrored
# by the dashboard script's refreshStatus against the live form.
module SectionStatusHelper
  IN_PROGRESS = "in progress".freeze

  def section_status(response, key)
    return "" unless response.answered?(key)

    label = response.self_rating_label(key)
    label ? "✓ #{label}" : IN_PROGRESS
  end
end
