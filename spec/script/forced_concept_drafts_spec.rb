require "rails_helper"
require Rails.root.join("script/model_comparison")

RSpec.describe ForcedConceptDrafts do
  let(:user)     { User.create!(email: "forced@example.com", name: "Forced", language: "ruby_rails") }
  let(:out)      { StringIO.new }
  let(:prompts)  { [] }
  let(:concept)  { "proportionality" }
  let(:kind)     { ExerciseSection::DesignComparison }
  let(:draft_dir) { ModelComparison::CONCEPT_DRAFT_DIR.join(concept) }

  # A single-section retry carries the concept it was asked for, as a provider following the fixed-concept line would.
  before do
    seen = prompts
    connection = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(ClaudeService::API_URL) do |env|
          body   = JSON.parse(env.body)
          system = body["system"].is_a?(Array) ? body["system"].first["text"] : body["system"]
          prompt = body["messages"].last["content"]
          seen << prompt
          text = FakeService.new("unused").send(:call, system: system, prompt: prompt)[:text]
          if prompt.include?("must be exactly `proportionality`")
            set = JSON.parse(text)
            text = { kind.key => set.fetch(kind.key).merge("concept" => "proportionality") }.to_json
          end
          [ 200, {}, { "content" => [ { "type" => "text", "text" => text } ],
                       "usage" => { "input_tokens" => 70, "output_tokens" => 30 } }.to_json ]
        end
      end
    end
    allow_any_instance_of(ClaudeService).to receive(:build_connection).and_return(connection)
    FileUtils.rm_rf(draft_dir)
  end

  after { FileUtils.rm_rf(draft_dir) }

  it "reads the draft guidance line from the concept's design note" do
    expect(described_class.guidance_for(concept)).to start_with("- The proportionality concept")
    expect { described_class.guidance_for("god_object") }.to raise_error(ArgumentError, /No design note/)
  end

  it "accepts the concept for design comparison only inside the block, and puts everything back" do
    forced = described_class.new(concept)

    forced.with_concept do
      expect(ConceptVocabulary.for_section(kind.key, "ruby_rails")).to include(concept)
      expect(ConceptVocabulary.selectable_for_section(kind.key, "ruby_rails", rung: "junior")).to include(concept)
      expect(ConceptVocabulary.selectable_for_section("code_review", "ruby_rails", mode: :application_code)).not_to include(concept)
    end

    expect(ConceptVocabulary.for_section(kind.key, "ruby_rails")).not_to include(concept)
    expect(kind.hosted_concepts).not_to include(concept)
  end

  it "puts everything back when the block raises" do
    expect { described_class.new(concept).with_concept { raise "boom" } }.to raise_error("boom")

    expect(ConceptVocabulary.for_section(kind.key, "ruby_rails")).not_to include(concept)
    expect(kind.hosted_concepts).not_to include(concept)
  end

  describe "the prompt override" do
    let(:guidance) { described_class.guidance_for(concept) }
    let(:forced)   { described_class.new(concept) }

    # Answers the retry with the concept it was asked for, as the Faraday stub above does, with no connection at all.
    let(:capturing_class) do
      Class.new(AiService) do
        attr_reader :sent_prompts

        def initialize(api_key = "no-network-key")
          super
          @sent_prompts = []
        end

        private

        def build_connection = nil

        def call(system:, prompt:, **)
          @sent_prompts << prompt
          set  = FakeService::EXERCISE_PROBLEM_SET.deep_dup
          kind = ExerciseSection::DesignComparison
          text = if prompt.include?("must be exactly `proportionality`")
            { kind.key => set.fetch(kind.key).merge("concept" => "proportionality") }.to_json
          else
            set.to_json
          end
          { text: text, input_tokens: 1, output_tokens: 1, truncated: false }
        end
      end
    end

    before do
      pin_code_review_mode(:application_code)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::SCENARIO_FLAVOR_WEIGHTS).and_return(:general)
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: nil)
    end

    def ordinary_prompt(service)
      service.generate_exercise(user, language: "ruby_rails")
      service.sent_prompts.last
    end

    it "leaves an ordinary prompt on a separate, unmodified service byte-identical before, during and after the experiment" do
      plain        = capturing_class.new
      experimental = capturing_class.new
      before_experiment = ordinary_prompt(plain)
      inside_block      = forced.with_concept { ordinary_prompt(plain) }
      during = forced.with_concept do
        forced.draft(experimental, user, rung: "senior")
        ordinary_prompt(plain)
      end
      after_experiment = ordinary_prompt(plain)

      expect(inside_block).to include(concept)
      expect(during).to eq(inside_block)
      expect(after_experiment).to eq(before_experiment)
      [ before_experiment, inside_block, during, after_experiment ].each { |prompt| expect(prompt).not_to include(guidance) }
      expect(experimental.sent_prompts.last).to include(guidance).once
      expect(plain.singleton_class.ancestors.first).to eq(plain.singleton_class)
      expect(experimental.singleton_class.ancestors.first).not_to eq(experimental.singleton_class)
    end

    it "adds the guidance line exactly once to each retry prompt, including a second draft from the same service" do
      experimental = capturing_class.new

      sections = forced.with_concept { 2.times.map { forced.draft(experimental, user, rung: "senior") } }

      expect(experimental.sent_prompts.size).to eq(2)
      experimental.sent_prompts.each do |prompt|
        expect(prompt).to include(guidance).once
        expect(prompt).to include("must be exactly `proportionality`")
        expect(prompt[/Return JSON matching this schema exactly:\n(.*)\z/m, 1].scan(/^  "(\w+)": \{/).flatten).to eq([ kind.key ])
      end
      expect(sections).to all(include("concept" => concept, "pitched_at" => "senior"))
    end

    it "leaves GenerationPrompt and ConceptGuidance themselves untouched" do
      experimental = capturing_class.new
      ancestors_before = [ GenerationPrompt.ancestors, GenerationPrompt::ConceptGuidance.ancestors ]

      forced.with_concept { forced.draft(experimental, user, rung: "junior") }

      expect([ GenerationPrompt.ancestors, GenerationPrompt::ConceptGuidance.ancestors ]).to eq(ancestors_before)
      expect(render_generation_prompt(user, "ruby_rails")).not_to include(guidance)
    end
  end

  it "judge_concept drafts every rung through the retry path with the guidance line, and judges each draft" do
    ModelComparison.new(api_key: "sk-ant-runner", out: out).judge_concept(user.id, concept, per_rung: 1)

    retries = prompts.select { |prompt| prompt.include?("must be exactly `proportionality`") }
    expect(retries.size).to eq(KindDifficulty::LEVELS.size)
    retries.each { |prompt| expect(prompt).to include(described_class.guidance_for(concept)).once }

    KindDifficulty::LEVELS.each do |rung|
      saved = JSON.parse(draft_dir.join("#{rung}-1.json").read)
      expect(saved).to include("concept" => concept, "pitched_at" => rung)
      expect(saved.dig("answer_key", "better")).to be_in(kind::PIECES)
      expect(out.string).to match(%r{tmp/judge_concept/proportionality/#{rung}-1\.json: rung=#{rung} status=keep solve=(match|mismatch)})
    end
    ModelComparison::CANDIDATES.fetch("judge").each do |route|
      expect(out.string).to include("=== judge_concept: #{route[:model]}", "blind solve, #{route[:model]}:")
    end
    expect(out.string).not_to include("better", "answer_key", "deciding_fact")
    expect(ConceptVocabulary.for_section(kind.key, "ruby_rails")).not_to include(concept)
  end

  it "judge_concept plans the drafts on the user's own day" do
    user.update!(time_zone: "Tokyo")
    zones = []
    allow_any_instance_of(AiService).to receive(:retry_section).and_wrap_original do |original, *args|
      zones << Time.zone.name
      original.call(*args)
    end

    ModelComparison.new(api_key: "sk-ant-runner", out: out).judge_concept(user.id, concept, per_rung: 1)

    expect(zones).to eq([ "Tokyo" ] * KindDifficulty::LEVELS.size)
  end

  it "judge_concept prints a failed draft as an error row and judges the rest" do
    calls = 0
    allow_any_instance_of(AiService).to receive(:retry_section).and_wrap_original do |original, *args|
      calls += 1
      raise AiService::RateLimitError, "slow down" if calls == 1

      original.call(*args)
    end

    ModelComparison.new(api_key: "sk-ant-runner", out: out).judge_concept(user.id, concept, per_rung: 1)

    expect(out.string.scan(/status=error AiService::RateLimitError: slow down/).size)
      .to eq(ModelComparison::CANDIDATES.fetch("judge").size)
    expect(out.string.scan(/status=keep/).size).to eq((KindDifficulty::LEVELS.size - 1) * ModelComparison::CANDIDATES.fetch("judge").size)
  end
end
