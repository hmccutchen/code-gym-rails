require "rails_helper"

RSpec.describe CallProfiles do
  it "raises for a purpose with no profile, so a typo fails at the call site" do
    expect { described_class.fetch("generate_exercises") }.to raise_error(KeyError)
    expect { described_class.worst_case_seconds_for("generate_exercises") }.to raise_error(KeyError)
  end

  it "times a purpose with no read timeout of its own at the default, with every retry" do
    expect(described_class.worst_case_seconds_for("explain_differently"))
      .to eq(described_class.worst_case_call_seconds(described_class::READ_TIMEOUT))
  end

  it "times a single-attempt purpose as one connection and one read" do
    expect(described_class.worst_case_seconds_for("judge_review"))
      .to eq(described_class::OPEN_TIMEOUT + described_class::REVIEW_JUDGE_READ_TIMEOUT)
  end

  it "answers the same worst case as a request built from the same profile" do
    described_class::BY_PURPOSE.each_key do |purpose|
      request = AiService.request_for(purpose, system: "s", prompt: "p")

      expect(described_class.worst_case_seconds_for(purpose)).to eq(request.worst_case_seconds), purpose
    end
  end
end
