require "rails_helper"

RSpec.describe ExerciseDraft do
  let(:user) { User.create!(email: "draft@example.com", name: "Draft", skill_level: "senior") }
  let(:generated) { [] }
  let(:rendered) { [] }
  let(:prompt) do
    Struct.new(:rendered) do
      def render(only: nil, fixed_concept: nil)
        rendered << { only: only&.key, fixed_concept: fixed_concept }
        "rendered prompt"
      end
    end.new(rendered)
  end
  let(:reply) { FakeService::EXERCISE_PROBLEM_SET.deep_dup }
  let(:recorded) { [] }
  let(:provider) do
    described_class::Provider.new(
      prompt: ->(*, **) { prompt },
      generate: lambda { |generating_user, purpose, language, text, **options|
        generated << { user: generating_user, purpose: purpose, language: language, prompt: text, **options }
        reply
      },
      record_suggestion: ->(suggestion) { recorded << suggestion.name }
    )
  end

  def draft_for(language: "ruby_rails", mode: :application_code)
    described_class::Draft.new(user: user, language: language, problem_set: {}, plan: Struct.new(:code_review_mode).new(mode),
                               kinds: [], difficulty: KindDifficulty.none, ladders: {}, history: [],
                               suggested_concepts: [], unusable_sections: [])
  end

  it "keeps the draft to its user and language, the plan, the drafted inputs and the ingest results" do
    expect(described_class::Draft.members)
      .to eq(%i[user language problem_set plan kinds difficulty ladders history suggested_concepts unusable_sections])
  end

  it "takes the provider calls as callables and the draft as its only retry context" do
    expect(described_class::Provider.members).to eq(%i[prompt generate record_suggestion])
    expect(described_class.method(:retry_section).parameters)
      .to eq([ %i[req draft], %i[req kind], %i[req concept], %i[keyreq provider], %i[key deadline] ])
  end

  it "drafts the day through one generate_exercise call and returns the ingested set" do
    deadline = GenerationDeadline.new(1.hour.from_now)

    draft = described_class.call(user, language: "ruby_rails", provider: provider, blocking: true, deadline: deadline)

    expect(generated).to eq([ { user: user, purpose: "generate_exercise", language: "ruby_rails", prompt: "rendered prompt",
                                subject: "problem set", blocking: true, deadline: deadline } ])
    expect(rendered).to eq([ { only: nil, fixed_concept: nil } ])
    expect(draft).to have_attributes(user: user, language: "ruby_rails")
    expect(draft.problem_set.keys).to match_array(draft.kinds.map(&:key))
  end

  it "refuses an unsupported language before it plans or calls" do
    expect { described_class.call(user, language: "cobol", provider: provider) }.to raise_error(SetupError)
    expect(generated).to be_empty
  end

  it "retries one kind with its concept fixed, keeping back time for the re-judge" do
    draft = described_class.call(user, language: "ruby_rails", provider: provider)
    generated.clear
    rendered.clear
    ends_at = 1.hour.from_now
    reply.replace("pattern" => FakeService::EXERCISE_PROBLEM_SET["pattern"].deep_dup)

    section = described_class.retry_section(draft, ExerciseSection::Pattern, "service_objects",
                                            provider: provider, deadline: GenerationDeadline.new(ends_at))

    expect(rendered).to eq([ { only: "pattern", fixed_concept: "service_objects" } ])
    expect(generated.sole).to include(user: user, purpose: "retry_section", language: "ruby_rails", subject: "pattern retry")
    expect(generated.sole[:deadline].ends_at).to eq(ends_at - AiService.worst_case_seconds_for("judge_section"))
    expect(section).to include("concept" => "service_objects", "pitched_at" => "senior")
  end

  it "renders a retry prompt carrying none of the rejected section's text, so the retry starts from fresh pieces" do
    real_prompt = provider.with(prompt: lambda { |*args, **options|
      GenerationPrompt.new(*args, **options, retention_annotation: ->(*) { })
    })
    draft = described_class.call(user, language: "ruby_rails", provider: real_prompt)
    rejected = draft.problem_set.fetch("design_comparison").merge(
      "piece_a" => "def rejected_piece_alpha = 1", "piece_b" => "def rejected_piece_beta = 2",
      "scenario" => "REJECTED-SCENARIO", "answer_key" => { "better" => "a", "deciding_fact" => "REJECTED-FACT" }
    )
    draft = draft.with(problem_set: draft.problem_set.merge("design_comparison" => rejected))
    generated.clear
    reply.replace("design_comparison" => FakeService::EXERCISE_PROBLEM_SET["design_comparison"].deep_dup)

    described_class.retry_section(draft, ExerciseSection::DesignComparison, rejected["concept"], provider: real_prompt)

    expect(generated.sole[:prompt]).to include(rejected["concept"])
    expect(generated.sole[:prompt]).not_to include("rejected_piece_alpha", "rejected_piece_beta", "REJECTED-SCENARIO", "REJECTED-FACT")
  end

  it "records each suggested concept through the provider when the set is finished, logging a failed one and keeping on" do
    suggestion = Struct.new(:bucket, :name)
    draft = draft_for.with(suggested_concepts: [ suggestion.new("ruby_rails", "first"), suggestion.new("ruby_rails", "second") ])
    failing = provider.with(record_suggestion: lambda { |entry|
      raise "db down" if entry.name == "first"

      recorded << entry.name
    })
    allow(GenerationDiagnostics).to receive(:new).and_return(instance_double(GenerationDiagnostics, finished: nil))
    allow(Rails.logger).to receive(:warn)

    described_class.finish(draft, {}, provider: failing)

    expect(recorded).to eq(%w[second])
    expect(Rails.logger).to have_received(:warn).with(/SuggestedConcept recording failed: db down/)
  end

  describe ".retry_ladders" do
    it "gives a one-section retry only that section's ladder rungs" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")
      ConceptReference.create!(concept: "scope_creep", language: ConceptBucket.for("plan_review", "ruby_rails"),
                               ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")
      user.update!(skill_level: "junior")

      expect(described_class.send(:retry_ladders, draft_for, ExerciseSection::Pattern))
        .to eq("junior" => { "n_plus_one" => "j" })
      expect(described_class.send(:retry_ladders, draft_for, ExerciseSection::PlanReview))
        .to eq("junior" => { "scope_creep" => "j" })
    end

    it "loads a retry's ladders for the draft's language and code_review mode" do
      allow(GenerationLadders).to receive(:for).and_call_original

      described_class.send(:retry_ladders, draft_for(language: "javascript", mode: :schema_review), ExerciseSection::CodeReview)

      expect(GenerationLadders).to have_received(:for).with(anything, "javascript", :schema_review)
    end
  end
end
