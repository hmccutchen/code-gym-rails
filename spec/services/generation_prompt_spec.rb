require "rails_helper"

RSpec.describe GenerationPrompt do
  let(:user) { User.new(email: "render@example.com", name: "Render", skill_level: "senior", focus_areas: %w[caching]) }

  let(:history) do
    [ { date: "2026-10-14", concepts: { "code_review" => "n_plus_one", "pattern" => "" }, scenarios: [ "ticket queue" ],
        sections_answered: 1, sections_total: 2, self_ratings: { "code_review" => "too_hard" },
        ai_ratings: { "code_review" => "developing" }, answered_sections: %w[code_review] } ]
  end

  let(:plan) do
    plan_for(third: :challenge, fourth: :plan_review, shared_concept: "memoization",
             reinforcement: [ { concept: "memoization", bucket: "ruby_rails", tier: "reduced" } ],
             due_checks: [ ConceptMastery.new(concept: "n_plus_one", language: "ruby_rails") ],
             established: [ ConceptMastery.new(concept: "caching", language: "ruby_rails") ],
             fourth_reinforcement: [ { concept: "scope_creep", bucket: "plan_review", tier: "standard" } ],
             fourth_established: [ ConceptMastery.new(concept: "scope_creep", language: "plan_review") ],
             code_review_source: RealSource::APPLICATION_CODE.first)
  end

  let(:difficulty) do
    KindDifficulty.new(levels: { "challenge" => "principal_engineer", "pattern" => "mid_level" }, locked: %w[challenge])
  end

  let(:ladders) do
    { "principal_engineer" => { "memoization" => "a principal rung" }, "senior" => { "n_plus_one" => "a senior rung" } }
  end

  def build(language = "ruby_rails")
    GenerationPrompt.new(user, language, plan: plan, history: history, difficulty: difficulty, ladders: ladders,
                         retention_annotation: generation_retention_annotation)
  end

  def retry_render(prompt)
    prompt.render(only: ExerciseSection::Challenge, fixed_concept: "memoization")
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

      expect(retried).to include("This section's concept must be exactly `memoization`")
      expect(retried).not_to include("as their concept today")
      expect(prompt.render).to eq(build.render)
      expect(prompt.render).to include("as their concept today")
    end

    it "raises for an unsupported language on render and on schema" do
      expect { build("mixed").render }.to raise_error(AiService::SetupError, /Unsupported generation language/)
      expect { build("mixed").schema }.to raise_error(AiService::SetupError, /Unsupported generation language/)
    end
  end

  describe "forwarding the code-review mode to every kind" do
    def guidance_for(kind, language, mode, rung)
      config = AiService.config_for(language)
      kind.generation_guidance(
        vocabulary: ConceptVocabulary.selectable_for_section(kind.key, language, mode: mode, rung: rung),
        label: config[:label], mode: mode, artifact: config[:schema_artifact],
        test_framework: config[:test_framework], source: nil, rung: rung
      )
    end

    it "changes nothing for a kind other than code_review, at every language, mode and rung" do
      others = ExerciseSection.all - [ ExerciseSection::CodeReview ]
      combinations = DailyExercise::LANGUAGES.product(DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys, KindDifficulty::LEVELS, others)

      combinations.each do |language, mode, rung, kind|
        expect(guidance_for(kind, language, mode, rung)).to eq(guidance_for(kind, language, nil, rung)),
          "#{kind.key} guidance differs with mode #{mode} (#{language}, #{rung})"
      end
    end
  end

  describe "the difficulty block" do
    let(:user) { User.create!(email: "diagnostics@example.com", name: "Diagnostics") }

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

      FakeService.new("fake-key").generate_exercise(user, language: "ruby_rails")

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
