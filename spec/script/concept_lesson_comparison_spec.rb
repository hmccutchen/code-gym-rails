require "rails_helper"
require Rails.root.join("script/concept_lesson_comparison")

RSpec.describe ConceptLessonComparison do
  let(:out)     { StringIO.new }
  let(:dir)     { Pathname(Dir.mktmpdir) }
  let(:prompts) { [] }

  let(:reference) do
    {
      "tagline" => "Doing it twice leaves the same state.",
      "explanation" => "An idempotent action can repeat without piling up effects.",
      "code_example" => "def charge!\n  return if charged?\nend",
      "senior_lens" => "Reach for it wherever a retry can happen.",
      "guide_plain_language" => "You can run it again and nothing extra happens.",
      "guide_worked_example" => "Before and after.",
      "guide_pitfalls" => "People think it means the code runs once.",
      "ladder_junior" => "A double-submitted form.",
      "ladder_senior" => "A retried job.",
      "ladder_principal_engineer" => "Exactly-once delivery across services."
    }
  end

  let(:lesson) do
    {
      "definition" => "An action is idempotent if doing it twice leaves the same state.",
      "comparison" => "An elevator call button.",
      "comparison_limit" => "The button sends no emails.",
      "situations" => [ "A double tap.", "A retried webhook." ],
      "habits" => [ { "habit" => "Send the end state.", "catch" => "A late message can overwrite a newer one." } ]
    }
  end

  # Answers with the candidate's lesson only when the prompt asked for one, so
  # a spec can tell which prompt reached the provider.
  before do
    seen = prompts
    current, candidate = reference, reference.merge("lesson" => lesson)
    connection = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(ClaudeService::API_URL) do |env|
          prompt = JSON.parse(env.body)["messages"].last["content"]
          seen << prompt
          text = (prompt.include?('"lesson"') ? candidate : current).to_json
          [ 200, {}, { "content" => [ { "type" => "text", "text" => text } ],
                       "usage" => { "input_tokens" => 1_000, "output_tokens" => 2_000 } }.to_json ]
        end
      end
    end
    allow_any_instance_of(ClaudeService).to receive(:build_connection).and_return(connection)
  end

  after { FileUtils.rm_rf(dir) }

  def run(*concepts, candidate:)
    described_class.new(api_key: "sk-ant-test", candidate: candidate, out: out, dir: dir).run(concepts)
  end

  def comparison = dir.join("comparison.md").read

  describe ".candidate_prompt" do
    let(:today) { AiService.allocate.send(:build_concept_reference_prompt, "idempotency", AiService::LANGUAGE_CONFIG.fetch("ruby_rails")) }

    it "keeps every line of today's prompt and adds the lesson block before the schema" do
      candidate = described_class.candidate_prompt(today)

      today.lines.map(&:strip).reject { |line| line == "}" }.each { |line| expect(candidate).to include(line) }
      expect(candidate.index("Then write a short lesson")).to be < candidate.index(described_class::INSTRUCTION_ANCHOR)
      expect(candidate).to include('"lesson": {')
      expect(candidate.rstrip).to end_with("}")
    end

    it "refuses a prompt that has lost its anchors" do
      expect { described_class.candidate_prompt("Write a reference.") }.to raise_error(ArgumentError, /anchors/)
    end
  end

  describe ".resolve" do
    it "finds a concept's bucket, honours an explicit one, and refuses an unknown concept" do
      expect(described_class.resolve("caching_strategy")).to eq([ "architecture", "caching_strategy" ])
      expect(described_class.resolve("javascript/shallow_module")).to eq([ "javascript", "shallow_module" ])
      expect { described_class.resolve("proportionality") }.to raise_error(ArgumentError, /no vocabulary/)
      expect { described_class.resolve("architecture/idempotency") }.to raise_error(ArgumentError, /no vocabulary/)
    end
  end

  it "sends today's prompt without --candidate and the candidate prompt with it" do
    run("idempotency", candidate: false)
    run("idempotency", candidate: true)

    expect(prompts.first).not_to include('"lesson"')
    expect(prompts.last).to include('"lesson": {')
  end

  it "writes no ConceptReference, exercise or ApiUsage row" do
    expect { run("idempotency", candidate: true) }
      .not_to change { [ ConceptReference.count, DailyExercise.count, ApiUsage.count ] }
  end

  it "leaves the shipped prompt unchanged after a candidate run" do
    run("idempotency", candidate: true)

    expect(AiService.allocate.send(:build_concept_reference_prompt, "idempotency", AiService::LANGUAGE_CONFIG.fetch("ruby_rails")))
      .not_to include('"lesson"')
  end

  it "puts the checklist first, then current, candidate and the target side by side" do
    run("idempotency", candidate: false)
    run("idempotency", candidate: true)

    expect(comparison.index("## Reviewer checklist")).to be < comparison.index("## idempotency (ruby_rails)")
    expect(comparison).to include("Does the everyday comparison map exactly", "Is each \"catch\" a real limit", "fit a phone screen")
    current, candidate, target = %w[Current Candidate Hand-written].map { |title| comparison.index("### #{title}") }
    expect([ current, candidate, target ]).to eq([ current, candidate, target ].sort)
    expect(comparison).to include("An elevator call button.", "- Send the end state. Catch: A late message can overwrite a newer one.")
    expect(comparison).to include("Press it five times")
  end

  it "says which variant has not been run yet" do
    run("caching_strategy", candidate: false)

    expect(comparison).to include("### Candidate lesson\n\nNot run yet.")
    expect(comparison).not_to include("Hand-written target")
  end

  it "prints words, sections and the plain-language checks for each lesson" do
    run("idempotency", candidate: true)

    expect(out.string).to match(%r{ruby_rails/idempotency\s+candidate\s+\d+ words\s+sections: definition,comparison,comparison_limit,situations,habits})
    expect(out.string).to include("failures: none", "$0.0220")
    expect(comparison).to include("- Sections present: definition, comparison, comparison_limit, situations, habits")
  end

  it "lists the target's sections and checks it like any lesson" do
    target = described_class.target_for("idempotency")

    expect(target[:sections]).to eq(described_class::SECTIONS.keys)
    expect(PlainLanguageChecks.report(target[:text])[:placeholder_phrases]).to be_empty
  end

  it "records a failed concept as an error row and keeps going" do
    allow_any_instance_of(ClaudeService).to receive(:generate_concept_reference).and_wrap_original do |original, user, concept, bucket|
      raise AiService::InvalidResponseError, "bad JSON" if concept == "shallow_module"

      original.call(user, concept, bucket)
    end

    run("shallow_module", "idempotency", candidate: false)

    expect(out.string).to include("ruby_rails/shallow_module", "error: AiService::InvalidResponseError")
    expect(comparison).to include("The last run failed: AiService::InvalidResponseError: bad JSON")
    expect(comparison).to include("**tagline**\n\nDoing it twice")
  end
end
