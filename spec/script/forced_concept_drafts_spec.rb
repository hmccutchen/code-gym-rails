require "rails_helper"
require Rails.root.join("script/model_comparison")

RSpec.describe ForcedConceptDrafts do
  let(:user)     { User.create!(email: "forced@example.com", name: "Forced", language: "ruby_rails") }
  let(:out)      { StringIO.new }
  let(:prompts)  { [] }
  let(:concept)  { "proportionality" }
  let(:kind)     { ExerciseSection::DesignComparison }
  let(:draft_dir) { ModelComparison::CONCEPT_DRAFT_DIR.join(concept) }

  # Answers the way FakeService would, except that a single-section retry
  # carries the concept it was asked for, as a provider following the
  # fixed-concept line would.
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
      expect(ProblemSetIngest.vocabulary_for(kind.key, "ruby_rails")).to include(concept)
      expect(ProblemSetIngest.selectable_vocabulary_for(kind.key, "ruby_rails", rung: "junior")).to include(concept)
      expect(ProblemSetIngest.selectable_vocabulary_for("code_review", "ruby_rails", mode: :application_code)).not_to include(concept)
    end

    expect(ProblemSetIngest.vocabulary_for(kind.key, "ruby_rails")).not_to include(concept)
    expect(kind.hosted_concepts).not_to include(concept)
  end

  it "puts everything back when the block raises" do
    expect { described_class.new(concept).with_concept { raise "boom" } }.to raise_error("boom")

    expect(ProblemSetIngest.vocabulary_for(kind.key, "ruby_rails")).not_to include(concept)
    expect(kind.hosted_concepts).not_to include(concept)
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
    expect(ProblemSetIngest.vocabulary_for(kind.key, "ruby_rails")).not_to include(concept)
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
