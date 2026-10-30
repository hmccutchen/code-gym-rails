module CodeReviewHelper
  def changed_lines_label(changed)
    return "" if changed.empty?

    runs = changed.sort.slice_when { |previous, number| number != previous + 1 }
    spans = runs.map { |run| run.one? ? run.first.to_s : t("sections.code_review.changed_range", first: run.first, last: run.last) }
    t("sections.code_review.changed_lines", count: changed.size, lines: spans.join(", "))
  end
end
