module ExerciseMixLadders
  extend ActiveSupport::Concern

  included do
    helper_method :ladder_preparation, :ladder_coverage_label
  end

  private

  def ladder_coverage
    @ladder_coverage ||= LadderCoverage.for(current_user)
  end

  def ladder_coverage_label(kind)
    entry = ladder_coverage.for_kind(kind)
    t("exercise_mix.coverage", grounded: entry.grounded.size, total: entry.pairs.size)
  end

  def ladder_preparation
    count = ladder_coverage.gaps_for(KindDifficulty.for(current_user).targeted_kinds).size
    {
      count: count,
      button_label: t("exercise_mix.ladders_button", count: count),
      coverage: ExerciseSection.all.to_h { |kind| [ kind.key, ladder_coverage_label(kind) ] }
    }
  end
end
