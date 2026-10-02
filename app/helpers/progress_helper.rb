module ProgressHelper
  DEVELOPING = "developing_".freeze

  # Every standing the page can show, highest first: each rung, then
  # developing toward it, down to developing toward the lowest; then the two
  # non-rung states. The one order the bars and the counts share.
  STANDINGS = (KindDifficulty::LEVELS.reverse.flat_map { |rung| [ rung, :"#{DEVELOPING}#{rung}" ] } + %i[not_yet not_offered]).freeze

  # The legend states developing once, for every rung.
  LEGEND = (KindDifficulty::LEVELS.reverse + %i[developing not_yet not_offered]).freeze

  def standing_label(standing)
    return t("progress.rungs.#{standing}") if standing.is_a?(String)
    return t("progress.developing_toward", rung: t("progress.rungs.#{developing_rung(standing)}")) if developing_rung(standing)

    t("progress.standings.#{standing}")
  end

  def standing_counts(counts)
    STANDINGS.filter_map { |standing| "#{counts[standing]} #{standing_label(standing)}" if counts.fetch(standing, 0).positive? }.join(" · ")
  end

  # The rung a developing standing is working toward, or nil.
  def developing_rung(standing)
    standing.to_s.delete_prefix(DEVELOPING) if standing.is_a?(Symbol) && standing.start_with?(DEVELOPING)
  end

  # How many rungs, counted from the lowest, the standing holds.
  def held_rung_count(standing)
    return KindDifficulty::LEVELS.index(standing) + 1 if standing.is_a?(String)
    return KindDifficulty::LEVELS.index(developing_rung(standing)) if developing_rung(standing)

    0
  end
end
