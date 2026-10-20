require "rails_helper"

RSpec.describe DuckPrompt do
  let(:section) do
    { "title" => "Invoice totals", "scenario" => "A nightly job emails each customer their open invoices.",
      "question" => "What would you change before this ships?",
      "snippet" => "Customer.all.each do |customer|\n  customer.invoices.open.sum(:total)\nend", "answer_key" => "SENTINEL-KEY" }
  end

  def expect_duck_snapshot(name, request)
    expect(request.keys).to eq(%i[system history prompt])
    expect_prompt_snapshot("duck__#{name}__system", request[:system])
    expect_prompt_snapshot("duck__#{name}__prompt", request[:prompt])
    expect_prompt_snapshot("duck__#{name}__history", JSON.pretty_generate(request[:history]))
  end

  it "renders a first turn exactly as recorded, with no field outside the section's visible ones" do
    request = described_class.generate(section_data: section, message: "What is this even asking?", thread: [])

    expect_duck_snapshot("first_turn", request)
    expect(request.values.flatten.to_json).not_to include("SENTINEL-KEY")
  end

  it "renders a turn with history exactly as recorded" do
    thread = [ { role: "user", content: "I don't see anything wrong." },
               { role: "assistant", content: "What does each pass through the loop ask the database for?" } ]

    expect_duck_snapshot("with_history", described_class.generate(section_data: section, message: "Is it the loop?", thread: thread))
  end

  it "renders an empty message with no section data exactly as recorded" do
    expect_duck_snapshot("bare", described_class.generate(section_data: nil, message: "", thread: []))
  end

  it "cannot see the response, the review or another section, because it takes only one section's data" do
    expect(described_class.method(:generate).parameters).to eq([ [ :keyreq, :section_data ], [ :keyreq, :message ], [ :keyreq, :thread ] ])
  end
end
