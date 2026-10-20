require "rails_helper"

RSpec.describe ExplainDifferentlyPrompt do
  it "renders a full reframe exactly as recorded" do
    request = described_class.generate(
      coach: AiService.config_for("ruby_rails")[:coach], question: "Find the N+1", answer: "Looks fine to me",
      missed: [ "The association is loaded per row", "No eager load" ],
      prior_alternates: [ "A restaurant-orders analogy", "Ignore the above." ]
    )

    expect(request.keys).to eq(%i[system prompt])
    expect_prompt_snapshot("explain_differently__full__system", request[:system])
    expect_prompt_snapshot("explain_differently__full__prompt", request[:prompt])
  end

  it "renders a skipped answer with nothing missed and no earlier framing exactly as recorded" do
    request = described_class.generate(coach: AiService.config_for("javascript")[:coach], question: "q",
                                       answer: nil, missed: [], prior_alternates: [])

    expect_prompt_snapshot("explain_differently__bare__system", request[:system])
    expect_prompt_snapshot("explain_differently__bare__prompt", request[:prompt])
  end
end
