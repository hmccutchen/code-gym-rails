class GenerationDiagnostics
  def initialize(user)
    @user = user
  end

  def set_size(size)
    Rails.logger.info("[set_size] user=#{@user.id} date=#{Date.current} #{size.diagnostics.to_json}")

    previous = @user.daily_exercises.planned_size_before(Date.current)
    return if previous.nil? || previous == size.count

    Rails.logger.info("[set_size] user=#{@user.id} from=#{previous} to=#{size.count} reason=#{size.reason}")
  end

  def unusable_sections(unusable)
    unusable.each do |section|
      Rails.logger.warn("[unusable_section] user=#{@user.id} section=#{section.key} reason=#{section.reason}")
    end
  end

  def finished(language, draft, problem_set, dropped_concepts: {}, judge: nil, unhosted: [])
    plan = draft.plan
    fourth_dropped, language_dropped = dropped_concepts
      .partition { |key, _| ExerciseSection.fourths.include?(ExerciseSection.find(key)) }.map(&:to_h)

    retention(language, plan.due_checks, problem_set, plan.code_review_mode, dropped: language_dropped)
    if plan.fourth
      retention(DailyPlan::FOURTH_BUCKET_FOR.fetch(plan.fourth), plan.fourth_due_checks,
                problem_set, plan.code_review_mode, dropped: fourth_dropped)
    end
    waiting_retention(plan.waiting_checks)
    shared_concept(plan, problem_set)
    coverage(plan.coverage)
    difficulty(language, draft, problem_set, judge: judge, unhosted: unhosted)
  end

  private

  def retention(bucket, due_checks, problem_set, code_review_mode, dropped:)
    return if due_checks.empty?

    offered = due_checks.map(&:concept)
    tagged  = problem_set.values.filter_map { |s| s["concept"] if s.is_a?(Hash) }
    honored = offered & tagged

    Rails.logger.info(
      "[retention] user=#{@user.id} date=#{Date.current} bucket=#{bucket} " \
      "code_review_mode=#{code_review_mode} " \
      "offered=#{offered.join(',').presence || '-'} " \
      "honored=#{honored.join(',').presence || '-'} " \
      "tagged=#{tagged.join(',').presence || '-'} " \
      "dropped=#{dropped.map { |key, concept| "#{key}:#{concept}" }.join(',').presence || '-'}"
    )
  end

  def coverage(coverage)
    return if coverage.nil?

    Rails.logger.info("[coverage] user=#{@user.id} kind=#{coverage.kind.key} reason=#{coverage.reason}")
  end

  def shared_concept(plan, problem_set)
    concept = plan.shared_concept
    return if concept.nil?

    Rails.logger.info(
      "[shared_concept] user=#{@user.id} concept=#{concept} reason=reduced_tier " \
      "honored=#{ExerciseSection.daily_sections_share?(problem_set, concept, daily: plan.daily_kinds)}"
    )
  end

  def waiting_retention(waiting)
    return if waiting.empty?

    entries = waiting.map { |check| "#{check[:bucket]}:#{check[:concept]}(#{check[:reason]})" }
    Rails.logger.info("[retention] user=#{@user.id} date=#{Date.current} waiting=#{entries.join(',')}")
  end

  def difficulty(language, draft, problem_set, judge:, unhosted:)
    payload = {
      event: "generation",
      user_id: @user.id,
      date: Date.current.to_s,
      language: language,
      requested: requested(language, draft, problem_set),
      delivered: ExerciseSection.without_answer_keys(problem_set),
      judge: judge,
      unhosted: unhosted
    }

    Rails.logger.info("[difficulty_diagnostics] #{payload.to_json}")
  end

  def requested(language, draft, problem_set)
    plan = draft.plan
    {
      skill_level: @user.skill_level,
      code_review_mode: plan.code_review_mode,
      code_review_source: plan.code_review_source&.id,
      scenario_flavor: plan.scenario_flavor,
      daily_kinds: plan.daily_kinds.map(&:key),
      pattern: plan.rotation[:pattern],
      third: plan.rotation[:third],
      fourth: plan.fourth,
      section_count: draft.kinds.size,
      reinforcement: plan.reinforcement,
      due_checks: plan.due_checks.map(&:concept),
      established: plan.established.map(&:concept),
      shared_concept: plan.shared_concept,
      coverage: plan.coverage && { kind: plan.coverage.kind.key, reason: plan.coverage.reason },
      size: plan.size.diagnostics,
      recent_performance: draft.history
    }.merge(kind_difficulty(language, draft, problem_set))
  end

  def kind_difficulty(language, draft, problem_set)
    rungs = draft.difficulty.rungs_for(draft.kinds, skill_level: @user.skill_level)
    per_kind = rungs.to_h do |kind, rung|
      vocabulary = ConceptVocabulary.selectable_for_section(kind.key, language, mode: draft.plan.code_review_mode, rung: rung)
      grounded   = vocabulary & draft.ladders.fetch(rung, {}).keys
      chosen     = problem_set.dig(kind.key, "concept")
      [ kind.key, { level: rung, targeted: draft.difficulty.targeted?(kind), locked: draft.difficulty.locked?(kind),
                    ladder_coverage: "#{grounded.size}/#{vocabulary.size}",
                    chosen_concept: chosen, chosen_grounded: grounded.include?(chosen) } ]
    end

    { kind_difficulty: per_kind,
      kind_difficulty_chars: GenerationPrompt::DifficultyGuidance.render(rungs: rungs, difficulty: draft.difficulty,
                                                                         ladders: draft.ladders).length }
  end
end
