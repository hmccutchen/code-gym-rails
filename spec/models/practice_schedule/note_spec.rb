require "rails_helper"

RSpec.describe PracticeSchedule::Note do
  let(:note) do
    { "version" => 2, "policy" => 2, "sequence" => 4, "initial_ready" => true,
      "regular_kinds" => %w[code_review design_comparison], "selected_kinds" => %w[pattern],
      "assignments" => {}, "continuation" => { "kind_service" => { "pattern" => 4 }, "service" => {} } }
  end

  it "identifies only integer single-slot format versions" do
    [ 2, 3 ].each do |version|
      expect(described_class.single?(note.merge("version" => version))).to be(true)
    end
    [ 1, 2.0, 3.0, nil, 4, "2", "3" ].each do |version|
      expect(described_class.single?(note.merge("version" => version))).to be(false)
    end
    [ nil, {}, [], 2 ].each do |value|
      expect(described_class.single?(value)).to be(false)
    end
  end

  it "reads the single-slot continuation without legacy turn fields" do
    expect(described_class.decode(note)).to eq(note)
    expect(described_class.decode(note)).not_to equal(note)
  end

  it "retains registered kinds outside current preferences in committed service" do
    note["continuation"]["kind_service"]["architecture"] = 1
    expect(described_class.decode(note)).to eq(note)
  end

  it "rejects unknown fields, kinds and impossible service sequences" do
    changes = [ { "phase" => nil }, { "version" => 2.0 }, { "selected_kinds" => [] },
      { "continuation" => { "kind_service" => { "unknown" => 1 }, "service" => {} } },
      { "continuation" => { "kind_service" => { "pattern" => 5 }, "service" => {} } },
      { "continuation" => { "kind_service" => { "pattern" => -1 }, "service" => {} } },
      { "continuation" => { "kind_service" => { "pattern" => 1.0 }, "service" => {} } } ]
    changes.each do |change|
      expect { described_class.decode(note.merge(change)) }.to raise_error(ArgumentError)
    end
  end

  it "preserves strict assignment and service identity validation" do
    note["assignments"] = { "pattern" => { "concept" => "sync_vs_async", "bucket" => "architecture",
      "reason" => "retention", "adjustment" => "normal" } }
    expect { described_class.decode(note) }.to raise_error(ArgumentError)
  end
end

RSpec.describe PracticeSchedule::Note, "language-aware continuation" do
  let(:note) do
    { "version" => 3, "policy" => 2, "sequence" => 4, "initial_ready" => true,
      "regular_kinds" => %w[code_review design_comparison], "selected_kinds" => %w[pattern],
      "assignments" => {}, "continuation" => { "kind_service" => {
        "ruby_rails" => { "pattern" => 4 }, "javascript" => { "code_review" => 2 }
      }, "service" => { "ruby_rails" => { "pattern" => {
        "last_lane" => "practice", "last_maintenance" => nil,
        "concepts" => [ { "concept" => "memoization", "bucket" => "ruby_rails", "sequence" => 4 } ]
      } } } } }
  end

  it "reads independent generated-language service and returns an isolated copy" do
    decoded = described_class.decode(note)
    expect(decoded).to eq(note)
    decoded["continuation"]["kind_service"]["ruby_rails"]["pattern"] = 1
    expect(note.dig("continuation", "kind_service", "ruby_rails", "pattern")).to eq(4)
  end

  it "rejects assignment service without a generated-language namespace" do
    malformed = note.deep_dup
    malformed["continuation"]["service"] = note.dig("continuation", "service", "ruby_rails")
    expect { described_class.decode(malformed) }.to raise_error(ArgumentError)
  end

  it "rejects a non-integer version without accepting a single-slot schema" do
    expect { described_class.decode(note.merge("version" => 3.0)) }.to raise_error(ArgumentError)
  end

  it "rejects unknown languages, legacy flat maps and impossible sequences" do
    [ { "mixed" => {} }, { "other" => {} }, { "pattern" => 4 },
      { "ruby_rails" => { "unknown" => 1 } }, { "javascript" => { "pattern" => 5 } },
      { "ruby_rails" => { "pattern" => -1 } }, { "ruby_rails" => { "pattern" => 1.0 } },
      { "ruby_rails" => [] } ].each do |service|
      malformed = note.deep_dup
      malformed["continuation"]["kind_service"] = service
      expect { described_class.decode(malformed) }.to raise_error(ArgumentError)
    end
  end
end
