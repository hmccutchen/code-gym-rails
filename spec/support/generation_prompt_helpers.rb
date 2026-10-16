module GenerationPromptHelpers
  PLAN_DEFAULTS = {
    daily_kinds: DailyKinds::DEFAULT, rotation: { pattern: :pattern, third: :challenge, fourth: :plan_review }, fourth: :plan_review,
    reinforcement: [], due_checks: [], established: [],
    fourth_reinforcement: [], fourth_due_checks: [], fourth_established: [],
    code_review_mode: :application_code, code_review_source: nil, scenario_flavor: :general,
    shared_concept: nil, coverage: nil, waiting_checks: nil, size: nil
  }.freeze

  # pattern:, third: and fourth: fill the default pair's rotation, so a spec names a day the way SectionRotation rolls one.
  def plan_for(**overrides)
    rolled   = overrides.extract!(:pattern, :third).merge(overrides.slice(:fourth))
    rotation = PLAN_DEFAULTS[:rotation].merge(rolled)

    DailyPlan::Result.new(**PLAN_DEFAULTS.merge(rotation: rotation, **overrides))
  end

  # The real curated method, bound to a service that can never open a connection; never a reimplementation.
  def generation_retention_annotation
    @generation_retention_annotation ||= Class.new(AiService) do
      private def build_connection = nil
    end.new("no-network-key").method(:annotate_retention_concept)
  end

  def render_generation_prompt(user, language = "ruby_rails", history: [], difficulty: KindDifficulty.none,
                        ladders: {}, only: nil, fixed_concept: nil, **plan_overrides)
    GenerationPrompt.new(user, language, plan: plan_for(**plan_overrides), history: history,
                         difficulty: difficulty, ladders: ladders,
                         retention_annotation: generation_retention_annotation)
                    .render(only: only, fixed_concept: fixed_concept)
  end

  def generation_schema(user, language = "ruby_rails", only: nil, **plan_overrides)
    GenerationPrompt.new(user, language, plan: plan_for(**plan_overrides), history: [],
                         difficulty: KindDifficulty.none, ladders: {},
                         retention_annotation: generation_retention_annotation)
                    .schema(only: only)
  end
end

RSpec.configure do |config|
  config.include GenerationPromptHelpers
end
