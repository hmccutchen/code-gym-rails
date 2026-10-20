require "rails_helper"

RSpec.describe DifficultyPrompt do
  let(:sections) do
    { "code_review"    => { "question" => "What is wrong here?", "snippet" => "Order.all.each { |o| o.user.name }" },
      "pattern"        => { "title" => "Memoize", "question" => "When would you cache this?" },
      "ambiguity_hunt" => { "title" => "Leaderboard", "request" => "Add a leaderboard.", "question" => "What needs clarifying?",
                            "planted_ambiguities" => [ "AH-SECRET-ONE", "AH-SECRET-TWO" ] },
      "challenge"      => nil }
  end

  it "renders the assessment exactly as recorded, with no answer key and an empty heading for a missing section" do
    request = described_class.generate(coach: AiService.config_for("ruby_rails")[:coach], sections: sections)

    expect(request.keys).to eq(%i[system prompt])
    expect_prompt_snapshot("difficulty__system", request[:system])
    expect_prompt_snapshot("difficulty__prompt", request[:prompt])
    expect(request.values.join).not_to include("AH-SECRET")
  end

  it "cannot see a response, answers, ratings or history, because it takes only the coach and the sections" do
    expect(described_class.method(:generate).parameters).to eq([ [ :keyreq, :coach ], [ :keyreq, :sections ] ])
  end

  it "has guidance for exactly the levels it can offer" do
    expect(described_class::GUIDANCE.keys).to eq(DailyResponse::DIFFICULTY_LEVELS)
  end
end
