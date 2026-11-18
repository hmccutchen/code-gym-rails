require "rails_helper"

RSpec.describe ExplanationReplyPrompt do
  let(:request) do
    described_class.generate(concept: "N plus one", phrasing: "In your own words, what does N plus one do?",
                             explanation: "It runs one query per row, I think, but I'm not sure about includes.")
  end

  it "renders its system prompt and prompt exactly as recorded" do
    expect(request.keys).to eq(%i[system prompt])
    expect_prompt_snapshot("explanation_reply__system", request[:system])
    expect_prompt_snapshot("explanation_reply__prompt", request[:prompt])
  end

  it "takes the concept, the phrasing and the explanation, and nothing else" do
    expect(described_class.method(:generate).parameters).to eq([ %i[keyreq concept], %i[keyreq phrasing], %i[keyreq explanation] ])
  end

  it "carries each of the five reply rules" do
    expect(described_class::SYSTEM.squish)
      .to include("Say what was sound in the explanation")
      .and include("Correct at most one explicit misunderstanding, and only one the explanation actually states")
      .and include("When the engineer says they are unsure, say so plainly")
      .and include("say you are not sure rather than correct it")
      .and include("Never manufacture a correction for a correct explanation")
      .and include('"correction": null')
      .and include("Never ask for another answer, another attempt or a follow-up")
  end

  it "fences the explanation as the engineer's text" do
    expect(request[:prompt]).to include("<engineer_text>\nIt runs one query per row")
    expect(request[:system]).to include(UserText::PROMPT_RULE)
  end
end
