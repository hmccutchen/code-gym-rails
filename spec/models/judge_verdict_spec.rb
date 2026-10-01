require "rails_helper"

RSpec.describe JudgeVerdict do
  let(:kind) { ExerciseSection::CodeReview }
  let(:section) { { "question" => "What is wrong?", "snippet" => "code", "concept" => "n_plus_one", "teaching_note" => "hint" } }

  it "parses keep" do
    expect(described_class.parse({ "status" => "keep" }, kind: kind).status).to eq(:keep)
  end

  it "parses an edit, applies only prose fields, and leaves the artifact untouched" do
    verdict = described_class.parse(
      { "status" => "edit", "issues" => [ { "type" => "padding", "evidence" => "Once upon" } ],
        "fields" => { "question" => "What is wrong with the loop?" } }, kind: kind
    )
    edited = verdict.apply(section)
    expect(edited["question"]).to eq("What is wrong with the loop?")
    expect(edited["snippet"]).to eq("code")
    expect(section["question"]).to eq("What is wrong?")
  end

  it "rejects an edit that touches an artifact field, the concept, or an unknown field" do
    %w[snippet concept pitched_at bogus].each do |field|
      expect {
        described_class.parse({ "status" => "edit", "issues" => [ { "type" => "padding", "evidence" => "x" } ],
                                "fields" => { field => "y" } }, kind: kind)
      }.to raise_error(described_class::Invalid, /#{field}/)
    end
  end

  it "rejects an unknown issue type, an unknown principle, and a blank evidence" do
    expect { described_class.parse({ "status" => "edit", "issues" => [ { "type" => "vibes", "evidence" => "x" } ], "fields" => { "question" => "q" } }, kind: kind) }
      .to raise_error(described_class::Invalid, /vibes/)
    expect { described_class.parse({ "status" => "reject", "principle" => "too_hard", "evidence" => "x", "reason" => "r" }, kind: kind) }
      .to raise_error(described_class::Invalid, /too_hard/)
    expect { described_class.parse({ "status" => "reject", "principle" => "underdetermined", "evidence" => "", "reason" => "r" }, kind: kind) }
      .to raise_error(described_class::Invalid, /evidence/)
  end

  it "rejects a rejection whose reason is missing, blank, or not a string" do
    base = { "status" => "reject", "principle" => "underdetermined", "evidence" => "x" }
    [ {}, { "reason" => " " }, { "reason" => [ "a", "b" ] } ].each do |reason|
      expect { described_class.parse(base.merge(reason), kind: kind) }.to raise_error(described_class::Invalid, /reason/)
    end
    expect(described_class.parse(base.merge("reason" => " It never says. "), kind: kind).reason).to eq("It never says.")
  end

  it "rejects an edit with no issues, a blank rewritten field, or a non-hash" do
    expect { described_class.parse({ "status" => "edit", "issues" => [], "fields" => { "question" => "q" } }, kind: kind) }.to raise_error(described_class::Invalid)
    expect { described_class.parse({ "status" => "edit", "issues" => [ { "type" => "padding", "evidence" => "x" } ], "fields" => { "question" => " " } }, kind: kind) }.to raise_error(described_class::Invalid)
    expect { described_class.parse([], kind: kind) }.to raise_error(described_class::Invalid)
  end

  it "keeps the closed lists in one place" do
    expect(described_class::ISSUE_TYPES).to eq(%w[referential_ambiguity technical_ambiguity unstated_incidental_term leakage padding answer_instruction sequencing])
    expect(described_class::PRINCIPLES).to eq(%w[scope_mismatch unstated_prerequisite underdetermined reasoning_failure])
  end
  describe ".schema_for" do
    let(:schema) { described_class.schema_for(kind) }
    let(:shapes) { schema.fetch("anyOf").index_by { |shape| shape.dig("properties", "status", "const") } }

    def objects_in(node)
      return [] unless node.is_a?(Hash) || node.is_a?(Array)
      children = node.is_a?(Hash) ? node.values : node
      own = node.is_a?(Hash) && node["type"] == "object" ? [ node ] : []
      own + children.flat_map { |child| objects_in(child) }
    end

    it "offers one shape per status, named from STATUSES" do
      expect(shapes.keys).to eq(described_class::STATUSES)
    end

    it "draws issue types and principles from the closed lists" do
      expect(shapes["edit"].dig("properties", "issues", "items", "properties", "type", "enum")).to eq(described_class::ISSUE_TYPES)
      expect(shapes["reject"].dig("properties", "principle", "enum")).to eq(described_class::PRINCIPLES)
    end

    it "lets an edit rewrite only the kind's prose fields, none of them required" do
      [ ExerciseSection::CodeReview, ExerciseSection::Pattern, ExerciseSection::AmbiguityHunt ].each do |each_kind|
        fields = described_class.schema_for(each_kind)["anyOf"]
          .find { |shape| shape.dig("properties", "status", "const") == "edit" }.dig("properties", "fields")
        expect(fields["properties"].keys).to eq(each_kind.prose_fields)
        expect(fields["required"]).to eq([])
      end
    end

    # The provider refuses a schema with any open object.
    it "closes every object" do
      expect(objects_in(schema)).to all(include("additionalProperties" => false))
    end

    it "asks for no solve from a kind the judge does not solve" do
      shapes.each_value { |shape| expect(shape["properties"]).not_to have_key("better") }
    end

    it "requires the blind solve on every status for a kind the judge solves" do
      comparison = described_class.schema_for(ExerciseSection::DesignComparison)["anyOf"]

      comparison.each do |shape|
        expect(shape.dig("properties", "better")).to eq("type" => "string", "enum" => %w[a b])
        expect(shape["required"]).to include("better")
      end
      expect(objects_in(comparison)).to all(include("additionalProperties" => false))
    end
  end

  describe "the blind solve" do
    let(:comparison) { ExerciseSection::DesignComparison }

    it "reads the solve on every status" do
      expect(described_class.parse({ "status" => "keep", "better" => "a" }, kind: comparison).solve).to eq("a")
      edit = { "status" => "edit", "better" => "b", "issues" => [ { "type" => "padding", "evidence" => "x" } ],
               "fields" => { "question" => "Which fits?" } }
      expect(described_class.parse(edit, kind: comparison).solve).to eq("b")
      reject = { "status" => "reject", "better" => "a", "principle" => "underdetermined", "evidence" => "x", "reason" => "r" }
      expect(described_class.parse(reject, kind: comparison).solve).to eq("a")
    end

    it "refuses a verdict whose solve is missing or outside the options, without quoting it" do
      [ nil, "zebra-solve", "B" ].each do |solve|
        expect { described_class.parse({ "status" => "keep", "better" => solve }.compact, kind: comparison) }
          .to raise_error(described_class::Invalid) { |error| expect(error.message).not_to include(solve.to_s) if solve }
      end
    end

    it "carries no solve for a kind the judge does not solve" do
      expect(described_class.parse({ "status" => "keep", "better" => "a" }, kind: kind).solve).to be_nil
    end

    it "never lets an edit rewrite either piece or the answer key" do
      %w[piece_a piece_b answer_key].each do |field|
        raw = { "status" => "edit", "better" => "a", "issues" => [ { "type" => "padding", "evidence" => "x" } ],
                "fields" => { field => "rewritten" } }
        expect { described_class.parse(raw, kind: comparison) }.to raise_error(described_class::Invalid, /#{field}/)
      end
    end
  end
end
