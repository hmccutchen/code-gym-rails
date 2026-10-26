require "rails_helper"
require Rails.root.join("script/glossary_coverage_report")

RSpec.describe GlossaryCoverageReport do
  let(:tsv) do
    <<~TSV
      concept\tlanguage\tterm\tfirst_field\tvisible\tglossary\tconcept_key\tclass
      a\truby_rails\tfoo\tplain\tyes\tno\ta\tx
      a\truby_rails\tbig foo\tplain\tyes\tno\ta\tx
      b\tjavascript\tbar\tplain\tyes\tno\tb\tx
      b\tjavascript\tfoo\tplain\tno\tno\tb\tx
    TSV
  end
  let(:terms) { { "foo" => "A foo." } }
  let(:pattern) { Glossary.pattern_for(terms) }
  let(:rows) { described_class.parse(tsv) }
  let(:report) { described_class.new(rows, terms: terms, pattern: pattern) }

  it "counts visible terms by how the glossary covers them" do
    expect(report.summary).to eq(visible: 3, whole_term: 1, by_form: 0, inside_term: 1, unmatched: 1)
  end

  it "ranks unmatched terms by the distinct concept and language pairs they appear in" do
    expect(report.top_unmatched(5)).to eq([ [ "bar", 1 ] ])
  end

  it "counts a term the resolver resolves, but that is not a key, as by_form" do
    resolver = ->(term) { "foo" if term == "bar" }
    resolved = described_class.new(rows, terms: terms, pattern: pattern, resolver: resolver)

    expect(resolved.summary).to eq(visible: 3, whole_term: 2, by_form: 1, inside_term: 1, unmatched: 0)
  end

  it "prints the five numbers and the top unmatched terms" do
    out = StringIO.new
    report.print(out)

    expect(out.string).to include("visible: 3", "whole_term: 1", "by_form: 0", "inside_term: 1", "unmatched: 1", "bar")
  end
end
