require "rails_helper"

RSpec.describe PlantedKey, ".quote_tally" do
  let(:code) do
    "RSpec.describe AdoptPet do\n  it \"raises\" do\n    allow(Adoption).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)\n" \
      "    expect(Adoption.count).to eq(0)\n  end\nend"
  end
  let(:scenario) { "Pet adoption app: `AdoptPet` runs on Sidekiq, which keeps its queue in Redis." }

  def tally(texts, within: [ code ], scenario: self.scenario, language: "ruby_rails")
    described_class.quote_tally(texts, within: within, scenario: scenario, language: language)
  end

  it "counts each backticked span under exactly one of verbatim, reference, scenario and unresolved" do
    result = tally([ "`expect(Adoption.count).to eq(0)` always holds, since `Adoption.create!` is stubbed; " \
                     "jobs use `Redis`; `:null_store` hides it" ])

    expect(result.counts).to eq(verbatim: 1, reference: 1, scenario: 1, unresolved: 1)
    expect(result.unresolved).to eq([ ":null_store" ])
  end

  it "searches the code before the scenario, so a span found in both counts as verbatim" do
    result = tally([ "`AdoptPet`" ], scenario: "The `AdoptPet` service.")

    expect(result.counts).to include(verbatim: 1, scenario: 0)
  end

  it "counts an elided call as a reference" do
    result = tally([ "`allow(Adoption).to receive(:create!)...RecordInvalid)` stubs the write" ])

    expect(result.counts).to include(reference: 1, unresolved: 0)
  end

  it "matches the scenario verbatim only, so a reference shape the code doesn't hold stays unresolved" do
    result = tally([ "`Sidekiq.enqueue`" ], scenario: "Jobs run on Sidekiq and enqueue to Redis.")

    expect(result.unresolved).to eq([ "Sidekiq.enqueue" ])
  end

  it "keeps the existing rules: a short span is skipped, and a text with no span counts as one unresolved part" do
    result = tally([ "`.` and `ab`", "The stub hides the write." ])

    expect(result.counts).to eq(verbatim: 0, reference: 0, scenario: 0, unresolved: 1)
  end

  it "treats a missing scenario as empty" do
    expect(tally([ "`Redis`" ], scenario: nil).unresolved).to eq([ "Redis" ])
  end

  it "is unresolved only when some span is unresolved, which is what counts toward the stop condition" do
    aggregate_failures do
      expect(tally([ "`Adoption.create!` and `AdoptPet`" ]).unresolved?).to be(false)
      expect(tally([ "`Adoption.create!` and `:null_store`" ]).unresolved?).to be(true)
    end
  end
end
