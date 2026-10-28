# Design notes: docs/code-notes/app/services/exercise_draft.md
class ExerciseDraft
  # prompt(user, language, plan:, history:, difficulty:, ladders:) builds a GenerationPrompt; generate(user, purpose, language, prompt, subject:, deadline:, blocking: false) returns the parsed reply; both raise. record_suggestion(suggestion) may raise.
  Provider = Data.define(:prompt, :generate, :record_suggestion)

  Draft = Data.define(:user, :language, :problem_set, :plan, :kinds, :difficulty, :ladders, :history,
                      :suggested_concepts, :unusable_sections)

  def self.call(user, language:, provider:, blocking: false, deadline: GenerationDeadline::NONE)
    LanguagePrompts.for(language)
    plan       = DailyPlan.for(user, language: language)
    GenerationDiagnostics.new(user).set_size(plan.size)
    history    = user.recent_performance
    difficulty = KindDifficulty.for(user)
    kinds      = plan.kinds
    ladders    = GenerationLadders.for(difficulty.rungs_for(kinds, skill_level: user.skill_level), language, plan.code_review_mode)
    prompt     = provider.prompt.call(user, language, plan: plan, history: history, difficulty: difficulty, ladders: ladders)

    reply = provider.generate.call(user, "generate_exercise", language, prompt.render,
                                   subject: "problem set", blocking: blocking, deadline: deadline)
    ingested = ProblemSetIngest.call(
      reply, language: language, expected_keys: kinds.map(&:key), daily: plan.daily_kinds, code_review_source: plan.code_review_source,
      pitched_at: difficulty.rungs(skill_level: user.skill_level), eased_for: eased_concepts_for(plan, difficulty)
    )

    diagnostics = GenerationDiagnostics.new(user)
    diagnostics.unusable_sections(ingested.unusable_sections)
    diagnostics.key_notes(ingested.key_notes, attempt: "draft", code_review_mode: plan.code_review_mode)
    Draft.new(user: user, language: language, problem_set: ingested.problem_set, plan: plan, kinds: kinds,
              difficulty: difficulty, ladders: ladders, history: history,
              suggested_concepts: ingested.suggested_concepts, unusable_sections: ingested.unusable_sections)
  end

  def self.retry_section(draft, kind, concept, provider:, deadline: GenerationDeadline::NONE)
    user, language = draft.user, draft.language
    prompt = provider.prompt.call(user, language, plan: draft.plan, history: draft.history, difficulty: draft.difficulty,
                                  ladders: retry_ladders(draft, kind))
    reply = provider.generate.call(user, "retry_section", language, prompt.render(only: kind, fixed_concept: concept),
                                   subject: "#{kind.key} retry",
                                   deadline: deadline.leaving(CallProfiles.worst_case_seconds_for("judge_section")))

    ingested = ProblemSetIngest.call(
      reply, language: language,
      expected_keys: [ kind.key ], daily: draft.plan.daily_kinds, fixed_concepts: { kind.key => concept },
      code_review_source: draft.plan.code_review_source,
      pitched_at: { kind.key => draft.difficulty.rung_for(kind, skill_level: user.skill_level) },
      eased_for: eased_concepts_for(draft.plan, draft.difficulty).slice(kind.key)
    )
    GenerationDiagnostics.new(user).key_notes(ingested.key_notes, attempt: "retry", code_review_mode: draft.plan.code_review_mode)
    ingested.problem_set[kind.key]
  end

  def self.finish(draft, set, provider:, dropped_concepts: {}, judge: nil, unhosted: [])
    record_suggested_concepts(draft.suggested_concepts, provider)
    GenerationDiagnostics.new(draft.user).finished(draft.language, draft, set,
                                                   dropped_concepts: dropped_concepts, judge: judge, unhosted: unhosted)
  end

  def self.retry_ladders(draft, kind)
    GenerationLadders.for(draft.difficulty.rungs_for([ kind ], skill_level: draft.user.skill_level), draft.language,
                          draft.plan.code_review_mode)
  end
  private_class_method :retry_ladders

  def self.eased_concepts_for(plan, difficulty)
    reduced_main   = reduced_concepts(plan.reinforcement)
    reduced_fourth = reduced_concepts(plan.fourth_reinforcement)

    ExerciseSection.all.reject { |kind| difficulty.locked?(kind) }.to_h do |kind|
      [ kind.key, kind.fourth? ? reduced_fourth : reduced_main ]
    end
  end
  private_class_method :eased_concepts_for

  def self.reduced_concepts(entries)
    entries.select { |h| h[:tier] == "reduced" }.map { |h| h[:concept] }
  end
  private_class_method :reduced_concepts

  def self.record_suggested_concepts(suggestions, provider)
    suggestions.each do |suggestion|
      provider.record_suggestion.call(suggestion)
    rescue => e
      Rails.logger.warn("SuggestedConcept recording failed: #{e.message}")
    end
  end
  private_class_method :record_suggested_concepts
end
