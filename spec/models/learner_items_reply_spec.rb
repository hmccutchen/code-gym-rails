require "rails_helper"

RSpec.describe LearnerItemsReply do
  let(:date) { Date.new(2026, 11, 16) }
  let(:day) do
    described_class::Day.new(date: date, duck_sections: %w[code_review], answered_sections: %w[code_review pattern],
                             note: true, explanation_section: "pattern")
  end
  let(:buckets) { %w[ruby_rails architecture] }

  def item(**overrides)
    { "concept" => "n_plus_one", "bucket" => "ruby_rails", "kind" => "misconception", "label" => "Each row runs its own query.",
      "evidence" => [ { "source" => "duck", "section" => "code_review" } ] }.merge(overrides.transform_keys(&:to_s))
  end

  def parse(*items, day: self.day) = described_class.parse({ "items" => items }, day: day, buckets: buckets)

  it "accepts an empty list of items" do
    result = parse

    expect(result.items).to eq([])
    expect(result.dropped).to eq({})
  end

  it "refuses a reply that is not an object holding a list of items" do
    [ nil, [], {}, { "items" => "none" } ].each do |raw|
      expect { described_class.parse(raw, day: day, buckets: buckets) }.to raise_error(ProviderError::InvalidResponseError)
    end
  end

  it "keeps a valid item, stamping each reference with the set's date and ignoring any date or id in the reply" do
    result = parse(item("id" => 7, "evidence" => [ { "source" => "duck", "section" => "code_review", "date" => "2020-01-01" } ]))

    expect(result.items.sole).to have_attributes(concept: "n_plus_one", bucket: "ruby_rails", kind: "misconception", term: nil,
                                                 label: "Each row runs its own query.",
                                                 evidence: [ { "date" => "2026-11-16", "source" => "duck", "section" => "code_review" } ])
  end

  it "drops each kind of invalid item and keeps the rest" do
    result = parse(
      item(kind: "strength"),
      item(concept: "not_a_concept"),
      item(bucket: "javascript"),
      item(concept: "caching_strategy"),
      item(label: "x" * (LearnerItem::MAX_LABEL_LENGTH + 1)),
      item(label: "Two\nlines."),
      item(label: " "),
      item(kind: "term", term: "eager <load>"),
      item(kind: "term", term: "t" * (LearnerItem::MAX_TERM_LENGTH + 1)),
      item(kind: "term"),
      "not an item",
      item(concept: nil),
      item(kind: "concept", label: "Practise eager loading.")
    )

    expect(result.items.map(&:kind)).to eq(%w[concept])
    expect(result.dropped).to eq(unknown_kind: 1, unknown_concept: 3, bad_label: 3, bad_term: 3, malformed: 2)
  end

  it "keeps a term item's term, squished, and ignores a term on any other kind" do
    result = parse(item(kind: "term", term: "  eager   load "), item(kind: "concept", term: "ignored"))

    expect(result.items.map(&:term)).to eq([ "eager load", nil ])
  end

  describe "evidence" do
    it "keeps a duck or answer reference only for a section that has that source" do
      result = parse(item(evidence: [ { "source" => "duck", "section" => "pattern" }, { "source" => "answer", "section" => "pattern" },
                                      { "source" => "answer", "section" => "challenge" } ]))

      expect(result.items.sole.evidence).to eq([ { "date" => "2026-11-16", "source" => "answer", "section" => "pattern" } ])
    end

    it "drops a note reference that names a section, and keeps one that does not" do
      result = parse(item(evidence: [ { "source" => "note", "section" => "code_review" }, { "source" => "note" } ]))

      expect(result.items.sole.evidence).to eq([ { "date" => "2026-11-16", "source" => "note" } ])
    end

    it "gives an explanation reference the stored section and drops one naming another" do
      result = parse(item(evidence: [ { "source" => "explanation" } ]),
                     item(concept: "memoization", evidence: [ { "source" => "explanation", "section" => "code_review" } ]))

      expect(result.items.sole.evidence).to eq([ { "date" => "2026-11-16", "source" => "explanation", "section" => "pattern" } ])
      expect(result.dropped).to eq(no_evidence: 1)
    end

    it "drops a reference to a blank source" do
      blank = described_class::Day.new(date: date, duck_sections: [], answered_sections: [], note: false, explanation_section: nil)

      result = parse(item(evidence: [ { "source" => "note" } ]), item(evidence: [ { "source" => "explanation" } ]),
                     item(evidence: [ { "source" => "duck", "section" => "code_review" } ]), day: blank)

      expect(result.items).to eq([])
      expect(result.dropped).to eq(no_evidence: 3)
    end

    it "drops an unknown source, removes duplicates and keeps at most five references" do
      sources = [ { "source" => "chat" }, { "source" => "note" }, { "source" => "note" } ] +
                %w[code_review pattern].map { |section| { "source" => "answer", "section" => section } } +
                [ { "source" => "duck", "section" => "code_review" }, { "source" => "explanation" } ] +
                [ { "source" => "answer", "section" => "code_review" } ]
      result = parse(item(evidence: sources))

      expect(result.items.sole.evidence.size).to eq(LearnerItem::MAX_EVIDENCE)
      expect(result.items.sole.evidence.uniq.size).to eq(LearnerItem::MAX_EVIDENCE)
    end

    it "drops an item whose evidence is missing or not a list" do
      expect(parse(item(evidence: nil), item(evidence: "duck")).dropped).to eq(no_evidence: 2)
    end
  end
end
