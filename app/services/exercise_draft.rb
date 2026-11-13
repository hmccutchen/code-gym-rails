# Design notes: docs/code-notes/app/services/exercise_draft.md
class ExerciseDraft
  # prompt(user, language, plan:, history:, delivered_history:, difficulty:, kind_rungs:, skill_level:, ladders:, adjustments:) builds a GenerationPrompt; generate(user, purpose, language, prompt, subject:, deadline:) returns the parsed reply; both raise. record_suggestion(suggestion) may raise.
  Provider = Data.define(:prompt, :generate, :record_suggestion)

  Draft = Data.define(:user, :skill_level, :language, :problem_set, :plan, :kinds, :difficulty, :kind_rungs, :ladders, :history, :delivered_history,
                      :suggested_concepts, :unusable_sections, :schedule_context, :adjustments) do
    def initialize(schedule_context: nil, adjustments: nil, **) = super
  end

  def self.call(user, language:, provider:, deadline: GenerationDeadline::NONE, schedule_context: nil) # rubocop:disable Metrics/MethodLength
    LanguagePrompts.for(language)
    planning_user = schedule_context ? User.find(user.id).tap { |record| record.assign_attributes(schedule_context.fetch(:settings)) } : user
    plan       = DailyPlan.for(planning_user, language: language, featured_concept: featured_concept_name(user), schedule_context: schedule_context)
    GenerationDiagnostics.new(user).set_size(plan.size)
    history    = user.recent_performance
    delivered_history = user.recent_delivered_content
    difficulty = schedule_context ? schedule_context.fetch(:difficulty) : KindDifficulty.for(user)
    skill_level = (schedule_context ? schedule_context.fetch(:skill_level) : user.skill_level)&.dup&.freeze
    kind_rungs = (schedule_context ? schedule_context.fetch(:kind_rungs) : difficulty.rungs(skill_level: skill_level)).transform_values { |rung| rung.dup.freeze }.freeze
    kinds      = plan.kinds
    adjustments = if plan.practice_schedule
      PracticeAdjustment.resolve(assignments: plan.assignments, difficulty: difficulty,
        rungs: kind_rungs.slice(*kinds.map(&:key)), reduced: eased_concepts_for(plan, difficulty))
    end
    plan = adjusted_plan(plan, adjustments) if adjustments
    ladders    = ladders_for(user, plan, kinds, kind_rungs, language)
    prompt     = provider.prompt.call(user, language, plan: plan, history: history, delivered_history: delivered_history,
                                     difficulty: difficulty, kind_rungs: kind_rungs, skill_level: skill_level, ladders: ladders,
                                     adjustments: adjustments)

    reply = provider.generate.call(user, "generate_exercise", language, prompt.render,
                                   subject: "problem set", deadline: deadline)
    files = code_review_files(plan, kind_rungs)
    ingested = ProblemSetIngest.call(
      reply, language: language, expected_keys: kinds.map(&:key), daily: plan.daily_kinds, code_review_source: plan.code_review_source,
      code_review_files: files, code_review_mode: plan.code_review_mode, pitched_at: kind_rungs, eased_for: eased_concepts_for(plan, difficulty),
      assignments: adjustments || {}, fixed_concepts: plan.assignments.transform_values { |entry| entry.fetch(:concept) }
    )

    diagnostics = GenerationDiagnostics.new(user)
    diagnostics.unusable_sections(ingested.unusable_sections)
    diagnostics.key_notes(ingested.key_notes, attempt: "draft", code_review_mode: plan.code_review_mode, code_review_files: files)
    Draft.new(user: user, skill_level: skill_level, language: language, problem_set: ingested.problem_set, plan: plan, kinds: kinds,
              difficulty: difficulty, kind_rungs: kind_rungs, ladders: ladders, history: history, delivered_history: delivered_history,
              suggested_concepts: ingested.suggested_concepts, unusable_sections: ingested.unusable_sections,
              schedule_context: schedule_context, adjustments: adjustments)
  end

  def self.adjusted_plan(plan, adjustments)
    note = plan.practice_schedule.deep_dup
    note["assignments"].each { |key, entry| entry["adjustment"] = adjustments.fetch(key).fetch(:mode) }
    plan.with(practice_schedule: PracticeSchedule::Note.decode(note))
  end
  private_class_method :adjusted_plan

  def self.retry_section(draft, kind, concept, cause: nil, provider:, deadline: GenerationDeadline::NONE)
    user, language = draft.user, draft.language
    prompt = provider.prompt.call(user, language, plan: draft.plan, history: draft.history, delivered_history: draft.delivered_history, difficulty: draft.difficulty,
                                  kind_rungs: draft.kind_rungs, skill_level: draft.skill_level,
                                  ladders: ladders_for(user, draft.plan, [ kind ], draft.kind_rungs, language), adjustments: draft.adjustments)
    reply = provider.generate.call(user, "retry_section", language, prompt.render(only: kind, fixed_concept: concept, retry_cause: cause),
                                   subject: "#{kind.key} retry",
                                   deadline: deadline.leaving(CallProfiles.worst_case_seconds_for("judge_section")))

    files = code_review_files(draft.plan, draft.kind_rungs)
    ingested = ProblemSetIngest.call(
      reply, language: language,
      expected_keys: [ kind.key ], daily: draft.plan.daily_kinds, fixed_concepts: { kind.key => concept },
      code_review_source: draft.plan.code_review_source, code_review_files: files,
      code_review_mode: draft.plan.code_review_mode,
      pitched_at: draft.kind_rungs.slice(kind.key),
      eased_for: eased_concepts_for(draft.plan, draft.difficulty).slice(kind.key),
      assignments: (draft.adjustments || {}).slice(kind.key)
    )
    GenerationDiagnostics.new(user).key_notes(ingested.key_notes, attempt: "retry", code_review_mode: draft.plan.code_review_mode,
                                                                  code_review_files: files)
    ingested.problem_set[kind.key]
  end

  def self.finish(draft, set, provider:, dropped_concepts:, judge:, unhosted:)
    record_suggested_concepts(draft.suggested_concepts, provider)
    GenerationDiagnostics.new(draft.user).finished(draft.language, draft, set,
                                                   dropped_concepts: dropped_concepts, judge: judge, unhosted: unhosted)
  end

  def self.featured_concept_name(user)
    FeaturedConcept.for(user)&.concept
  rescue ActiveRecord::ActiveRecordError => error
    Rails.logger.warn("Featured concept lookup failed for user #{user.id}, planning without it: #{error.class}")
    nil
  end
  private_class_method :featured_concept_name

  def self.code_review_files(plan, kind_rungs)
    ExerciseSection::CodeReview.file_range(files: plan.code_review_files, rung: kind_rungs.fetch(ExerciseSection::CodeReview.key))
  end
  private_class_method :code_review_files

  def self.ladders_for(user, plan, kinds, kind_rungs, language)
    GenerationLadders.for(user, kinds.index_with { |kind| kind_rungs.fetch(kind.key) }, language,
                          plan.code_review_mode, gotcha: plan.code_review_gotcha, featured_concept: plan.featured_concept)
  end
  private_class_method :ladders_for

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
