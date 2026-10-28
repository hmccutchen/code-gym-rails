require "rails_helper"

RSpec.describe PseudocodePrompt do
  let(:problem_statement) { "Merge overlapping ranges." }
  let(:pseudocode) { "sort ranges, then walk them" }

  it "renders the critique's system prompt and prompt exactly as recorded" do
    request = described_class.critique(problem_statement: problem_statement, pseudocode: pseudocode)

    expect(request.keys).to eq(%i[system prompt])
    expect_prompt_snapshot("pseudocode_critique__system", request[:system])
    expect_prompt_snapshot("pseudocode_critique__prompt", request[:prompt])
  end

  it "renders the translation's system prompt and prompt exactly as recorded" do
    request = described_class.translate(problem_statement: problem_statement, pseudocode: pseudocode,
                                        language_label: LanguagePrompts.for("javascript")[:label])

    expect(request.keys).to eq(%i[system prompt])
    expect_prompt_snapshot("pseudocode_translate__system", request[:system])
    expect_prompt_snapshot("pseudocode_translate__prompt", request[:prompt])
  end

  it "takes only the problem statement and the pseudocode, so no section field such as its answer key can reach either request" do
    expect(described_class.method(:critique).parameters).to eq([ %i[keyreq problem_statement], %i[keyreq pseudocode] ])
    expect(described_class.method(:translate).parameters)
      .to eq([ %i[keyreq problem_statement], %i[keyreq pseudocode], %i[keyreq language_label] ])
  end

  it "forbids every form of silent correction in the translation's system prompt" do
    expect(described_class::TRANSLATE_SYSTEM).to match(/omits an edge case, the code omits it too/i)
      .and match(/implement the wrong thing/i)
      .and match(/do not add error handling/i)
      .and match(/do not add comments/i)
      .and match(/syntactically valid/i)
  end
end
