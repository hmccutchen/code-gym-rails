# Drafts design comparison sections tagged with a concept the vocabulary does
# not hold yet, so the judge comparison can keep or reject real drafts before
# the concept ships. Read by ModelComparison#judge_concept only.
#
# Nothing shipped changes. For the length of #with_concept, this process
# accepts the concept in design comparison's vocabulary and hosting list and
# adds the draft guidance line from the concept's design note to the prompt,
# then puts all three back. The section itself comes from AiService's own
# single-section retry, which already asks for one named concept.
class ForcedConceptDrafts
  KIND = ExerciseSection::DesignComparison
  GUIDANCE_PATTERN = /<!-- draft-guidance:start -->\n(.+?)\n<!-- draft-guidance:end -->/m

  # The design note holding a concept's draft guidance line, between the
  # draft-guidance markers.
  NOTES = { "proportionality" => Rails.root.join("docs/proportionality-concept-2026-10-07.md") }.freeze

  def self.guidance_for(concept)
    path = NOTES.fetch(concept) { raise ArgumentError, "No design note for #{concept}; known: #{NOTES.keys.join(', ')}" }
    path.read[GUIDANCE_PATTERN, 1] or raise ArgumentError, "#{path} has no draft-guidance block"
  end

  def initialize(concept)
    @concept = concept
    @guidance_module = guidance_module(self.class.guidance_for(concept))
  end

  # Runs the block with the concept accepted for design comparison, and puts
  # every override back afterwards, whatever the block raised.
  def with_concept
    concept = @concept
    vocabulary = ProblemSetIngest.method(:vocabulary_for)
    hosted     = KIND.method(:hosted_concepts)

    ProblemSetIngest.define_singleton_method(:vocabulary_for) do |key, language|
      list = vocabulary.call(key, language)
      key == KIND.key ? list + [ concept ] : list
    end
    KIND.define_singleton_method(:hosted_concepts) { hosted.call + [ concept ] }
    yield
  ensure
    ProblemSetIngest.define_singleton_method(:vocabulary_for, vocabulary)
    KIND.define_singleton_method(:hosted_concepts, hosted)
  end

  # One design comparison at this rung, locked so the prompt pitches it
  # exactly there, drafted through the retry path with the concept fixed.
  # Call inside #with_concept.
  def draft(service, user, rung:)
    language = user.language_for_today
    service.singleton_class.prepend(@guidance_module) unless service.singleton_class.include?(@guidance_module)
    service.send(:retry_section, user, language, prompt_draft(service, user, language, rung), KIND, @concept)
  end

  private

  # The draft guidance line goes after the last concept-group line, where the
  # follow-up would put its own guidance method.
  def guidance_module(line)
    Module.new do
      define_method(:domain_modeling_guidance) { "#{super()}\n#{line}" }
    end
  end

  # The draft the retry reads its prompt options from: today's plan for this
  # user, with this one kind targeted and locked at the rung asked for.
  def prompt_draft(service, user, language, rung)
    plan       = DailyPlan.for(user, language: language)
    difficulty = KindDifficulty.new(levels: { KIND.key => rung }, locked: [ KIND.key ])
    kinds      = ExerciseSection.for_plan(third: plan.third, fourth: plan.fourth, pattern: plan.pattern)
    ladders    = service.send(:ladders_for, kinds, difficulty, language, plan.code_review_mode)
    history    = user.recent_performance
    options    = service.send(:exercise_prompt_options, plan, history, difficulty, ladders)

    AiService.const_get(:Draft).new(problem_set: {}, plan: plan, kinds: kinds, difficulty: difficulty, ladders: ladders,
                                    history: history, prompt_options: options, suggested_concepts: [], unusable_sections: [])
  end
end
