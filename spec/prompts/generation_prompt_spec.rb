require "rails_helper"

RSpec.describe GenerationPrompt do
  describe ".system_prompt" do
    DailyExercise::LANGUAGES.each do |language|
      it "renders the #{language} system prompt exactly as recorded" do
        config = LanguagePrompts.for(language)

        expect_prompt_snapshot("generation_system__#{language}", described_class.system_prompt(coach: config[:coach], focus: config[:focus]))
      end
    end

    it "takes only the coach and the focus, so it sees nothing about the engineer or the day" do
      expect(described_class.method(:system_prompt).parameters).to eq([ [ :keyreq, :coach ], [ :keyreq, :focus ] ])
    end
  end

  let(:user) { User.new(email: "render@example.com", skill_level: "senior", focus_areas: %w[caching]) }

  let(:history) do
    [ { date: "2026-10-14", sections: [ { key: "code_review", concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing" } ],
        completion: { answered: 1, total: 2, skipped_sections: %w[pattern] } } ]
  end
  let(:delivered_history) { [ { date: "2026-10-14", sections: [ { key: "code_review", concept: "n_plus_one", scenario: "ticket queue" } ] } ] }

  let(:plan) do
    plan_for(third: :challenge, fourth: :plan_review, shared_concept: "memoization",
             reinforcement: [ { concept: "memoization", bucket: "ruby_rails", tier: "reduced" } ],
             due_checks: [ ConceptMastery.new(concept: "n_plus_one", language: "ruby_rails") ],
             established: [ ConceptMastery.new(concept: "caching", language: "ruby_rails") ],
             fourth_reinforcement: [ { concept: "scope_creep", bucket: "plan_review", tier: "standard" } ],
             fourth_established: [ ConceptMastery.new(concept: "scope_creep", language: "plan_review") ],
             code_review_source: RealSource::APPLICATION_CODE.first.dup)
  end

  let(:difficulty) do
    KindDifficulty.new(levels: { "challenge" => "principal_engineer", "pattern" => "mid_level" }, locked: %w[challenge])
  end

  let(:ladders) do
    { ExerciseSection::Challenge => { "memoization" => "a principal rung" }, ExerciseSection::CodeReview => { "n_plus_one" => "a senior rung" } }
  end

  def build(language = "ruby_rails")
    GenerationPrompt.new(user, language, plan: plan, history: history, delivered_history: delivered_history, difficulty: difficulty, ladders: ladders,
                         retention_annotation: generation_retention_annotation)
  end

  it "separates assessed answers from repetition notes and omits unknown completion" do
    history.first[:completion] = nil
    history.first[:sections].first.delete(:concept)
    text = build.render
    expect(text).to include("Reviewed answer evidence:", "code_review (self: too_hard, ai: developing)",
                           "Delivered content — repetition avoidance only:", "ticket queue")
    expect(text).not_to include("1/2 answered", "ai: unreviewed", "skipped: pattern")
    history.clear
    expect(build.render).to include("No assessed performance history is available.", "ticket queue")
    expect(build.render).not_to include("first exercise set")
  end

  it "leaves the week's featured concept out of a section that hides its concept, and names it in no other line" do
    featured_concept = ConceptVocabulary::PLAN_REVIEW_CONCEPTS.first
    quiet_plan = plan.with(fourth_reinforcement: [], fourth_established: [])

    plain = GenerationPrompt.new(user, "ruby_rails", plan: quiet_plan, history: history, delivered_history: delivered_history, difficulty: difficulty, ladders: ladders,
                                 retention_annotation: generation_retention_annotation).render
    withheld = GenerationPrompt.new(user, "ruby_rails", plan: quiet_plan.with(featured_concept: featured_concept), history: history, delivered_history: delivered_history, difficulty: difficulty,
                                    ladders: ladders, retention_annotation: generation_retention_annotation).render

    expect(plain).to include(featured_concept)
    expect(withheld).not_to include(featured_concept)
    expect(withheld).to include(ConceptVocabulary::PLAN_REVIEW_CONCEPTS.second)
  end

  def retry_render(prompt)
    prompt.render(only: ExerciseSection::Challenge, fixed_concept: "memoization")
  end

  it "keeps level-dependent file counts compatible with the shared reasoning instruction" do
    user.skill_level = "principal_engineer"
    text = render_generation_prompt(user, code_review_files: :multi, only: ExerciseSection::CodeReview)

    expect(text).to include("shows 2 or 3 files", "within each kind's stated format and size limits")
    expect(text).not_to include("levels change reasoning, not length, files")
  end

  it "always carries the shared and kind baseline, with ladders refining rather than replacing it" do
    [ {}, { ExerciseSection::CodeReview => { "n_plus_one" => "trace a query hidden in a helper" } } ].each do |ladders|
      prompt = GenerationPrompt.new(user, "ruby_rails", plan: plan, history: [], delivered_history: [],
                                   difficulty: difficulty, ladders: ladders,
                                   retention_annotation: generation_retention_annotation).render
      definition = ExerciseSection::CodeReview.difficulty_definition(rung: "senior")

      expect(prompt).to include(definition.standard, definition.expectation)
      expect(prompt).to include("Concept ladders refine, never override, the applicable baseline and format.")
      expect(prompt).not_to include("For a concept not listed")
    end
  end

  it "passes the bug-hunt mode into the baseline on an initial render and a single-kind retry" do
    gotcha = BugHuntGotchas.for_language("ruby_rails").first
    bug_plan = plan.with(code_review_mode: :bug_hunt, code_review_source: nil, code_review_gotcha: gotcha)
    prompt = GenerationPrompt.new(user, "ruby_rails", plan: bug_plan, history: [], delivered_history: [],
                                  difficulty: difficulty, ladders: {}, retention_annotation: generation_retention_annotation)
    definition = ExerciseSection::CodeReview.difficulty_definition(rung: "senior", mode: :bug_hunt)

    [ prompt.render, prompt.render(only: ExerciseSection::CodeReview) ].each do |text|
      expect(text).to include(definition.standard, definition.expectation)
      expect(text).not_to include(ExerciseSection::CodeReview.difficulty_definition(rung: "senior").expectation)
      expect(text.scan(ExerciseSection::CodeReview::BugHunt::Prompt.expectation("senior")).size).to eq(1)
    end
  end

  it "states the comparison's level expectations once, in the shared baseline block" do
    text = build.render

    expect(text.scan(ExerciseSection::DesignComparison::RUNG_GUIDANCE.fetch("senior")).size).to eq(1)
  end

  def sql_during
    statements = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
      sql = event.payload[:sql]
      statements << sql unless event.payload[:name] == "SCHEMA" || sql.match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  def deep_freeze(value)
    return value if value.is_a?(Module)

    case value
    when Hash  then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
    when Array then value.each { |nested| deep_freeze(nested) }
    end
    value.freeze
  end

  describe "rendering from already-built inputs" do
    before do
      [ User, ConceptMastery, DailyExercise, ConceptReference ].each(&:columns_hash)
      [ user, plan, history, difficulty, ladders ].each(&:itself)
    end

    it "issues no SQL to construct, render, render a retry or build the schema" do
      statements = sql_during do
        prompt = build
        prompt.render
        retry_render(prompt)
        prompt.schema
        prompt.schema(only: ExerciseSection::Challenge)
      end

      expect(statements).to be_empty
    end

    it "mutates none of its inputs" do
      deep_freeze(history)
      deep_freeze(delivered_history)
      deep_freeze(ladders)
      plan.to_h.each_value { |value| deep_freeze(value) }
      difficulty.freeze
      attributes_before = user.attributes.dup
      prompt = build

      expect { prompt.render && retry_render(prompt) && prompt.schema }.not_to raise_error
      expect(user.attributes).to eq(attributes_before)
    end

    it "renders the same string twice" do
      prompt = build

      expect(prompt.render).to eq(prompt.render)
    end

    it "renders a retry without changing a later full render" do
      prompt = build
      retried = retry_render(prompt)

      expect(retried).to include("Its concept must be exactly `memoization`")
      expect(retried).not_to include("as their concept today")
      expect(prompt.render).to eq(build.render)
      expect(prompt.render).to include("as their concept today")
    end

    it "raises for an unsupported language on render and on schema" do
      expect { build("mixed").render }.to raise_error(SetupError, /Unsupported generation language/)
      expect { build("mixed").schema }.to raise_error(SetupError, /Unsupported generation language/)
    end
  end

  describe "forwarding the code-review mode to every kind" do
    def guidance_for(kind, language, mode, rung)
      config = LanguagePrompts.for(language)
      kind.generation_guidance(
        vocabulary: ConceptVocabulary.selectable_for_section(kind.key, language, mode: mode, rung: rung),
        label: config[:label], mode: mode, artifact: config[:schema_artifact],
        test_framework: config[:test_framework], source: nil, rung: rung
      )
    end

    it "changes nothing for a kind other than code_review, at every language, mode and rung" do
      others = ExerciseSection.all - [ ExerciseSection::CodeReview ]
      combinations = DailyExercise::LANGUAGES.product(DailyPlan::CODE_REVIEW_MODES, KindDifficulty::LEVELS, others)

      combinations.each do |language, mode, rung, kind|
        expect(guidance_for(kind, language, mode, rung)).to eq(guidance_for(kind, language, nil, rung)),
          "#{kind.key} guidance differs with mode #{mode} (#{language}, #{rung})"
      end
    end
  end

  describe "the difficulty block" do
    let(:user) { User.create!(email: "diagnostics@example.com") }

    before do
      user.update_columns(section_kind_levels: { "challenge" => "senior" }, locked_section_kinds: [ "challenge" ])
      user.reload
      pin_code_review_mode(:application_code)
      allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: :challenge, fourth: :plan_review)
    end

    it "is one renderer shared by the prompt and the diagnostics log, which reports its exact length" do
      rendered = []
      allow(GenerationPrompt::DifficultyGuidance).to receive(:render).and_wrap_original do |original, **inputs|
        rendered << inputs
        original.call(**inputs)
      end
      logged = nil
      allow(Rails.logger).to receive(:info) do |message|
        logged = message if message.is_a?(String) && message.start_with?("[difficulty_diagnostics]")
      end

      FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails").problem_set

      kinds = ExerciseSection.for_plan(daily: DailyKinds::DEFAULT, rotation: { pattern: nil, third: :challenge, fourth: :plan_review })
      expect(rendered.size).to eq(2)
      expect(rendered.uniq.size).to eq(1)
      expect(rendered.last[:rungs]).to eq(KindDifficulty.for(user).rungs_for(kinds, skill_level: user.skill_level))
      expect(rendered.last[:difficulty].locked?(ExerciseSection::Challenge)).to be(true)

      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))
      expect(payload.dig("requested", "kind_difficulty_chars"))
        .to eq(GenerationPrompt::DifficultyGuidance.render(**rendered.last).length)
      expect(payload.dig("requested", "kind_difficulty_chars")).to be > 0
    end
  end
end
