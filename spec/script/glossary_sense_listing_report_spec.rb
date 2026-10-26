require "rails_helper"
require Rails.root.join("script/glossary_sense_listing_report")

RSpec.describe GlossarySenseListingReport do
  let(:terms) { { "seam" => "A seam.", "index" => "An index.", "memo" => "A memo." } }
  let(:forms) { { "memo" => %w[memoized] } }
  let(:jsonl) do
    <<~JSONL
      {"source":"concept_references","id":"a/ruby","field":"explanation","text":"Think of a seam in the code, then memoized values."}
      {"source":"counts","concept_references":1}
      WARNING: loading took a while
      {"source":"daily_exercises","id":"d/1","field":"scenario","text":"Add an index here."}
    JSONL
  end
  let(:path) { Rails.root.join("tmp/sense_listing_#{SecureRandom.hex(4)}.jsonl") }
  let(:report) do
    described_class.new(described_class.read_rows(path), base_words: %w[index],
                        terms: terms, forms: forms, key_for: ->(word) { word == "memoized" ? "memo" : word.downcase })
  end

  before { File.write(path, jsonl) }
  after { FileUtils.rm_f(path) }

  it "skips the counts line and the non-JSON line" do
    expect(described_class.read_rows(path).map { |row| row["id"] }).to eq(%w[a/ruby d/1])
  end

  it "groups new matches by key, a form under its key, and leaves a base key out" do
    expect(report.groups.keys).to contain_exactly("seam", "memo")
  end

  it "prints each match with twenty characters either side, then a total" do
    out = StringIO.new
    report.print(out)

    expect(out.string).to eq(<<~TEXT)
      == memo (1)
        concept_references a/ruby explanation: …m in the code, then [memoized] values.…
      == seam (1)
        concept_references a/ruby explanation: …Think of a [seam] in the code, then m…
      == total matches: 2 across 2 keys
    TEXT
  end

  it "lists nothing and totals 0 when the base words are every key and form" do
    unchanged = described_class.new(described_class.read_rows(path), base_words: terms.keys + forms.values.flatten,
                                    terms: terms, forms: forms, key_for: ->(word) { word.downcase })
    out = StringIO.new
    unchanged.print(out)

    expect(out.string).to eq("== total matches: 0 across 0 keys\n")
  end

  context "when a new key overlaps a base key" do
    let(:terms) { { "adapter pattern" => "A pattern.", "adapter" => "An adapter." } }
    let(:forms) { {} }
    let(:rows) { [ { "source" => "s", "id" => "1", "field" => "f", "text" => "the adapter pattern here" }, { "source" => "s", "id" => "2", "field" => "f", "text" => "an adapter here" } ] }
    let(:overlap_report) { described_class.new(rows, base_words: [ "adapter pattern" ], terms: terms, forms: forms) }

    it "lets the longer base key win, so only the lone new key is listed" do
      expect(overlap_report.groups.transform_values(&:size)).to eq("adapter" => 1)
      expect(overlap_report.groups["adapter"].first).to include("[adapter]").and include("s 2 f")
    end
  end

  it "reads one base word per line, ignoring blanks" do
    File.write(path, "seam\n\nmemo\n")

    expect(described_class.read_words(path)).to eq(%w[seam memo])
  end
end
