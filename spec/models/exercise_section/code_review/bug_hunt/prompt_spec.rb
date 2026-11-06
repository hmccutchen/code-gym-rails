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

  it "states the purpose's length limit, the one ingest enforces, in the guidance and the schema" do
    limit = ExerciseSection::CodeReview::BugHunt::MAX_PURPOSE_LENGTH

    expect(guidance(ruby, "junior")).to include("one sentence of at most #{limit} characters")
    expect(described_class.schema_fragment).to include("one sentence of at most #{limit} characters")
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
    expect(described_class.judge_guidance_for(hunt)).to include("correct as written")
    expect(described_class.difficulty_definition(rung: "principal_engineer", section: hunt))
      .to eq(described_class.difficulty_definition(rung: "senior", section: hunt))
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

RSpec.describe ExerciseSection::CodeReview, "reviewing a bug_hunt section" do
  let(:hunt) do
    { "question" => "What's wrong, why, and how would you fix it?", "purpose" => "Remove every even number from nums.",
      "snippet" => "def remove_evens(nums)\n  nums.each { |n| nums.delete(n) if n.even? }\n  nums\nend",
      "concept" => "array_mutation_pitfalls", "answer_key" => { "issue" => "SENTINEL-KEY", "witness" => { "call" => "SENTINEL-CALL" } } }
  end
  let(:plain) { { "question" => "What is wrong?", "snippet" => "Order.all.each { |o| o.user.name }" } }

  it "grades a bug_hunt section against its goal, and leaves every other section's note as it was" do
    note = described_class.grading_note(section: hunt, answer: "a")

    expect(note).to include("judged against the goal line", "has missed the main point", "doesn't meet it")
    expect(described_class.grading_note(section: plain, answer: "a")).to start_with("Main point: the one planted issue")
  end

  it "gives the grader the goal and the snippet with its lines numbered as the page numbers them, and no key" do
    context = described_class.review_context(section: hunt, answer: "my answer", rating: "right_level")

    expect(context).to include("Goal: Remove every even number from nums.", "1 | def remove_evens(nums)",
                               "4 | end", "is not part of the code", "No program output was shown")
    expect(context).not_to include("SENTINEL")
  end

  it "shows the duck the goal and the numbered snippet, never the concept or the key" do
    context = SectionContext.render(hunt)

    expect(context).to include("Goal: Remove every even number from nums.", "2 |   nums.each")
    expect(context).not_to include("SENTINEL", "array_mutation_pitfalls")
  end

  it "leaves every other section's context as it was" do
    expect(SectionContext.render(plain)).to include("Code snippet:\nOrder.all.each { |o| o.user.name }")
    expect(SectionContext.render(plain)).not_to include("Goal:")
  end
end
