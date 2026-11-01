require "rails_helper"

RSpec.describe ProblemSetIngest, "quote tally on key notes" do
  let(:snippet) do
    "RSpec.describe AdoptPet do\n  it \"raises\" do\n    allow(Adoption).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)\n" \
      "    expect(Adoption.count).to eq(0)\n  end\nend"
  end
  let(:scenario) { "Pet adoption app: jobs run on Sidekiq, which keeps its queue in `Redis`." }

  def code_review(issue)
    { "concept" => "transaction_safety", "scenario" => scenario, "snippet" => snippet,
      "answer_key" => { "issue" => issue, "why_it_matters" => "A failed adoption leaves the pet adopted.", "fix" => "Assert the status." } }
  end

  def note(issue) = ingest(issue).key_notes.sole

  def ingest(issue)
    described_class.call({ "code_review" => code_review(issue) }, language: "ruby_rails", daily: DailyKinds::DEFAULT, expected_keys: [ "code_review" ])
  end

  it "notes a key whose spans are all verbatim, references or scenario facts as ok, with the tally" do
    result = note("`expect(Adoption.count).to eq(0)` always holds: `Adoption.create!` is stubbed, and `Redis` is separate.")

    expect(result.outcome).to eq("ok")
    expect(result.quotes.counts).to eq(verbatim: 1, reference: 1, scenario: 1, unresolved: 0)
  end

  it "notes quote_missing only for an unresolved span, and keeps the key" do
    result = ingest("`Adoption.create!` is stubbed, so `:null_store` hides it.")

    expect(result.key_notes.sole.outcome).to eq("quote_missing")
    expect(result.key_notes.sole.quotes.unresolved).to eq([ ":null_store" ])
    expect(result.problem_set["code_review"]).to have_key("answer_key")
  end

  it "searches the scenario as the server stored it, after the code" do
    result = note("`Redis` is not the database.")

    expect(result.quotes.counts).to include(scenario: 1, unresolved: 0)
  end

  it "carries no tally when the key was dropped, since there is nothing to count" do
    result = ingest("x" * (PlantedKey::MAX_LENGTH + 1)).key_notes.sole

    expect(result.outcome).to eq("too_long")
    expect(result.quotes).to be_nil
  end
end
