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

  it "rejects an edit with no issues, a blank rewritten field, or a non-hash" do
    expect { described_class.parse({ "status" => "edit", "issues" => [], "fields" => { "question" => "q" } }, kind: kind) }.to raise_error(described_class::Invalid)
    expect { described_class.parse({ "status" => "edit", "issues" => [ { "type" => "padding", "evidence" => "x" } ], "fields" => { "question" => " " } }, kind: kind) }.to raise_error(described_class::Invalid)
    expect { described_class.parse([], kind: kind) }.to raise_error(described_class::Invalid)
  end

  it "keeps the closed lists in one place" do
    expect(described_class::ISSUE_TYPES).to eq(%w[referential_ambiguity technical_ambiguity unstated_incidental_term leakage padding answer_instruction sequencing])
    expect(described_class::PRINCIPLES).to eq(%w[scope_mismatch unstated_prerequisite underdetermined reasoning_failure])
  end
end
