require "rails_helper"

RSpec.describe ExerciseSection::CodeReview::BugHunt::Prompt do
  let(:ruby) { BugHuntGotchas.find("rb_memo_falsy") }
  let(:javascript) { BugHuntGotchas.find("js_arrow_method") }

  def guidance(gotcha, rung) = described_class.guidance(gotcha: gotcha, rung: rung, vocabulary: [ gotcha.concept ])

  it "names the picked trap and offers only its concept" do
    text = guidance(ruby, "junior")

    expect(text).to include("Plant exactly this trap: #{ruby.rule}")
    expect(text).to include("exactly one: memoization")
  end

  it "holds Ruby to the core language and JavaScript to an ES module" do
    expect(guidance(ruby, "junior")).to include("Write core Ruby only")
    expect(guidance(javascript, "junior")).to include("Write core JavaScript as an ES module", "never timers")
  end

  it "pitches principal_engineer exactly as senior" do
    expect(guidance(ruby, "principal_engineer")).to eq(guidance(ruby, "senior"))
  end

  it "asks for looks_right_on from mid_level up" do
    expect(guidance(ruby, "junior")).not_to include("\"looks_right_on\" is a call")
    %w[mid_level senior principal_engineer].each do |rung|
      expect(guidance(ruby, rung)).to include("\"looks_right_on\" is a call")
    end
  end

  it "states the snapshot rule for async witnesses" do
    expect(guidance(javascript, "junior")).to include("snapshot of the state at the moment the call returns, never a live reference")
  end

  it "refuses to render without the picked gotcha" do
    expect { described_class.guidance(gotcha: nil, rung: "junior", vocabulary: []) }.to raise_error(ArgumentError)
  end

  it "asks for the purpose and the key's optional fields, and no scenario or diagram" do
    fragment = described_class.schema_fragment

    expect(fragment).to include('"purpose":', '"witness":', '"looks_right_on":', '"fixed_snippet":')
    expect(fragment).not_to include('"scenario":', '"diagram":')
  end

  it "keeps the schema's indentation contract" do
    lines = described_class.schema_fragment.lines

    expect(lines.first).to start_with('"code_review": {')
    expect(lines[1]).to start_with("    \"")
    expect(lines.last).to eq("  }")
  end
end

RSpec.describe ExerciseSection::CodeReview, "judging a bug_hunt section" do
  let(:hunt) { { "purpose" => "Remove every even number.", "snippet" => "x" } }
  let(:plain) { { "snippet" => "x" } }

  it "states the bug hunt task and guidance for a bug_hunt section only" do
    expect(described_class.judge_task_for(hunt)).to eq(described_class::BugHunt::Prompt::JUDGE_TASK)
    expect(described_class.judge_guidance_for(hunt)).to include("correct as written", "principal_engineer exactly as senior")
    expect(described_class.judge_task_for(plain)).to eq(described_class.judge_task)
    expect(described_class.judge_guidance_for(plain)).to be_nil
  end

  it "never lets the judge rewrite the purpose" do
    expect(described_class.prose_fields).not_to include("purpose")
  end

  it "leaves every other kind's judge task and guidance as they were" do
    (ExerciseSection.all - [ described_class ]).each do |kind|
      expect(kind.judge_task_for(hunt)).to eq(kind.judge_task)
      expect(kind.judge_guidance_for(hunt)).to eq(kind.judge_guidance)
    end
  end
end
