# Overrides apply only inside #with_concept, which puts them all back; nothing shipped changes.
class ForcedConceptDrafts
  KIND = ExerciseSection::DesignComparison
  GUIDANCE_PATTERN = /<!-- draft-guidance:start -->\n(.+?)\n<!-- draft-guidance:end -->/m

  # The draft guidance line sits between the draft-guidance markers in each note.
  NOTES = { "proportionality" => Rails.root.join("docs/proportionality-concept-2026-10-07.md") }.freeze

  def self.guidance_for(concept)
    path = NOTES.fetch(concept) { raise ArgumentError, "No design note for #{concept}; known: #{NOTES.keys.join(', ')}" }
    path.read[GUIDANCE_PATTERN, 1] or raise ArgumentError, "#{path} has no draft-guidance block"
  end

  def initialize(concept)
    @concept = concept
    @guidance_module = guidance_module(self.class.guidance_for(concept))
  end

  def with_concept
    concept = @concept
    vocabulary = ConceptVocabulary.method(:for_section)
    hosted     = KIND.method(:hosted_concepts)

    ConceptVocabulary.define_singleton_method(:for_section) do |key, language|
      list = vocabulary.call(key, language)
      key == KIND.key ? list + [ concept ] : list
    end
    KIND.define_singleton_method(:hosted_concepts) { hosted.call + [ concept ] }
    yield
  ensure
    ConceptVocabulary.define_singleton_method(:for_section, vocabulary)
    KIND.define_singleton_method(:hosted_concepts, hosted)
  end

  # Locked so the prompt pitches it exactly at this rung. Call inside #with_concept.
  def draft(service, user, rung:)
    language = user.language_for_today
    service.singleton_class.prepend(@guidance_module) unless service.singleton_class.include?(@guidance_module)
    service.send(:retry_section, user, language, prompt_draft(service, user, language, rung), KIND, @concept)
  end

  private

  # Goes after the last concept-group line, where a real guidance method would add its line.
  def guidance_module(line)
    Module.new do
      define_method(:domain_modeling_guidance) { "#{super()}\n#{line}" }
    end
  end

  # Today's plan for this user, with this one kind targeted and locked at the rung asked for.
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
