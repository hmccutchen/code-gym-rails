module ProgressHelper
  # Every standing the page can show, highest rung first, then the two
  # non-rung states; the one order the bars, the counts and the legend share.
  STANDINGS = (KindDifficulty::LEVELS.reverse + %i[not_yet not_offered]).freeze

  def standing_label(standing)
    standing.is_a?(String) ? t("progress.rungs.#{standing}") : t("progress.standings.#{standing}")
  end

  def standing_counts(counts)
    STANDINGS.filter_map { |standing| "#{counts[standing]} #{standing_label(standing)}" if counts.fetch(standing, 0).positive? }.join(" · ")
  end
end
