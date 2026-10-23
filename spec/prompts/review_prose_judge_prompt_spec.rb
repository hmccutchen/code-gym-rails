require "rails_helper"

RSpec.describe ReviewProseJudgePrompt do
  let(:projection) do
    ReviewProseVerdict.project("rating" => "partial", "correct" => [ "Spotted the loop" ],
                               "missed" => [ "The association is loaded per row", "No eager load" ],
                               "better_questions" => [], "next_step" => "Try includes", "improved_code" => "SENTINEL-CODE")
  end

  it "renders the verdict request exactly as recorded" do
    request = described_class.generate(kind: ExerciseSection::CodeReview, coach: "Rails", projection: projection)

    expect(request.keys).to eq(%i[response_schema system prompt])
    expect_prompt_snapshot("review_prose_judge__system", request[:system])
    expect_prompt_snapshot("review_prose_judge__prompt", request[:prompt])
    expect_prompt_snapshot("review_prose_judge__schema", JSON.pretty_generate(request[:response_schema]))
  end

  it "is never shown the answer, the problem or the grading note, because it takes only the kind, the coach and the prose" do
    expect(described_class.method(:generate).parameters).to eq([ [ :keyreq, :kind ], [ :keyreq, :coach ], [ :keyreq, :projection ] ])
  end

  it "gives guidance for exactly the issue types the verdict accepts" do
    expect(described_class::ISSUE_GUIDANCE.keys).to eq(ReviewProseVerdict::ISSUE_TYPES)
  end

  it "lists issue types from ReviewProseVerdict and carries the plain-language standard" do
    ReviewProseVerdict::ISSUE_TYPES.each { |type| expect(described_class::SYSTEM).to include("- #{type}:") }
    expect(described_class::SYSTEM).to include(PromptStandards::PLAIN_LANGUAGE_STANDARD.strip)
      .and include("reply with only the JSON verdict")
  end

  it "never asks the judge to remove a hedge or cut a next step's topics" do
    expect(described_class::SYSTEM).not_to match(/needless hedging|names more than one thing/)
    expect(described_class::SYSTEM).to include("Keep how sure each claim is")
      .and include("Keep every topic a next step names")
  end
end
